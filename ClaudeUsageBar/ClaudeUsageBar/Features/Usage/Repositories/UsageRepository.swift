import Foundation
import OSLog

/// Everything the ViewModel needs to render, already resolved — never an `Optional`, always
/// one of these cases.
internal nonisolated enum UsageRepositoryResult: Sendable, Equatable {
    case fresh(UsageSnapshot)
    case stale(UsageSnapshot, age: TimeInterval)
    case throttled(until: Date)
    case sessionExpired
    case failure(UsageRepositoryError)
}

internal nonisolated enum UsageRepositoryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Carries the underlying Keychain error so callers (the Views, via the ViewModel) can
    /// distinguish "no session" (`.itemNotFound`) from "access denied" (`.interactionNotAllowed`
    /// / `.missingAuthorization` / `.userDeniedAccess`) — two different, differently-actionable
    /// failure states that both originate here.
    case credentialsUnavailable(ClaudeCodeCredentialsError)
    case offline
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(Int)
    case decodingFailed
    case networkError

    internal var description: String {
        switch self {
        case .credentialsUnavailable(let underlying):
            return "no se pudo leer el token del Keychain: \(underlying.description)"
        case .offline:
            return "sin conexión de red"
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "429 rate_limit_error — sin Retry-After" }
            return "429 rate_limit_error — reintentar en \(Int(retryAfter))s"
        case .serverError(let code):
            return "HTTP inesperado \(code)"
        case .decodingFailed:
            return "no se pudo decodificar la respuesta"
        case .networkError:
            return "error de red no clasificado"
        }
    }
}

/// The sole owner of usage-fetch policy: orchestrates credentials → fetch → snapshot, caches
/// the last snapshot in `UserDefaults` (never the token), and decides when the network may be
/// touched (180s interval, 429 backoff, throttling). The ViewModel only ever asks — it never
/// decides.
@MainActor
internal final class UsageRepository {

    /// Baseline interval between fetches, and the interval reapplied after any non-429 attempt.
    private static let minimumFetchInterval: TimeInterval = 180

    /// 429 backoff ladder: 3 → 6 → 12 → 15 min, capped at the last step.
    private static let backoffSteps: [TimeInterval] = [180, 360, 720, 900]

    /// A cached snapshot older than this is presented as `.stale`, not `.fresh`.
    private static let freshnessTTL: TimeInterval = 600

    private static let cacheKey: String = "com.maxward.ClaudeUsageBar.cachedUsageSnapshot"

    private static let logger: Logger = Logger(subsystem: "com.maxward.ClaudeUsageBar", category: "UsageRepository")

    private struct CachedUsage: Codable, Sendable {
        internal let snapshot: UsageSnapshot
        internal let fetchedAt: Date
    }

    private let credentialsService: ClaudeCodeCredentialsServiceProtocol
    private let apiService: UsageAPIServiceProtocol
    private let userDefaults: UserDefaults

    private var consecutiveRateLimits: Int = 0

    /// The earliest instant a subsequent `refresh()` is allowed to touch the network. A call
    /// made before this returns `.throttled(until:)` without invoking either service.
    internal private(set) var nextAllowedFetch: Date = .distantPast

    internal init(
        credentialsService: ClaudeCodeCredentialsServiceProtocol,
        apiService: UsageAPIServiceProtocol,
        userDefaults: UserDefaults
    ) {
        self.credentialsService = credentialsService
        self.apiService = apiService
        self.userDefaults = userDefaults
    }

    // MARK: - Public Methods

    internal func refresh(now: Date = Date()) async -> UsageRepositoryResult {
        guard now >= nextAllowedFetch else {
            return .throttled(until: nextAllowedFetch)
        }

        // credentialsUnavailable and sessionExpired deliberately do NOT fall back to a cached
        // snapshot the way network-failure paths do: both are actionable states (fix the
        // Keychain access, re-authenticate) that a stale-but-plausible-looking number would
        // mask. Network failures, by contrast, say nothing about whether the session itself is
        // still good, so showing the last known snapshot there is the more useful default.
        //
        // Every return past the throttle guard records the attempt, including the ones that never
        // reach the network. Skipping it here left `nextAllowedFetch` in the past, and the polling
        // loop derives its sleep from that deadline — so an expired token or a missing Claude Code
        // session collapsed the interval to the loop's 1-second floor and re-read the Keychain
        // once per second, indefinitely.
        let credentials: ClaudeCodeCredentials
        do {
            credentials = try await credentialsService.readCredentials()
        } catch let credentialsError as ClaudeCodeCredentialsError {
            recordAttempt(now: now)
            return .failure(.credentialsUnavailable(credentialsError))
        } catch {
            recordAttempt(now: now)
            return .failure(.credentialsUnavailable(.malformedPayload))
        }

        // Pre-flight: an already-expired token never touches the network. Deliberately checks
        // against the injected `now`, not `credentials.isExpired`'s own `Date()` — every other
        // policy decision in this type shares one clock, and this one must too for tests to
        // drive it deterministically.
        guard credentials.expiresAt > now else {
            recordAttempt(now: now)
            return .sessionExpired
        }

        return await performFetch(accessToken: credentials.accessToken, allowRetry: true, now: now)
    }

    /// The user's explicit retry after the Keychain denied access — the one call allowed to ignore
    /// the fetch interval.
    ///
    /// Exempting it is safe precisely because it cannot be reached autonomously: on an
    /// authorization failure the ViewModel stops the polling loop and drops the wake observer, so
    /// nothing gets here without a human pressing "Reintentar". Without the exemption the denial's
    /// own recorded attempt would throttle that retry for 180s and disable the only action left on
    /// screen — which is also why this exists at all rather than the denial path simply skipping
    /// `recordAttempt`: the 401-then-denied-re-read path records one too, and would block the
    /// retry just the same.
    internal func retryIgnoringThrottle(now: Date = Date()) async -> UsageRepositoryResult {
        nextAllowedFetch = .distantPast
        return await refresh(now: now)
    }

    // MARK: - Private Methods

    private func performFetch(accessToken: String, allowRetry: Bool, now: Date) async -> UsageRepositoryResult {
        do {
            let snapshot: UsageSnapshot = try await apiService.fetchUsage(accessToken: accessToken)
            recordSuccess(snapshot: snapshot, now: now)
            return .fresh(snapshot)
        } catch let error as UsageAPIServiceError {
            return await handle(error, accessToken: accessToken, allowRetry: allowRetry, now: now)
        } catch {
            recordAttempt(now: now)
            return cachedResult(now: now) ?? .failure(.networkError)
        }
    }

    private func handle(
        _ error: UsageAPIServiceError,
        accessToken: String,
        allowRetry: Bool,
        now: Date
    ) async -> UsageRepositoryResult {
        switch error {
        case .unauthorized:
            recordAttempt(now: now)
            guard allowRetry else { return .sessionExpired }

            // Re-read the Keychain once; only retry if the token actually changed underneath
            // us. An identical token means the session itself is expired, not stale creds.
            let refreshed: ClaudeCodeCredentials
            do {
                refreshed = try await credentialsService.readCredentials()
            } catch let credentialsError as ClaudeCodeCredentialsError where credentialsError.isAuthorizationFailure {
                // Must surface, not collapse into .sessionExpired: this is the second read of a
                // single refresh, and swallowing it would hide a denial from the ViewModel's
                // authorization gate — leaving the polling loop alive to re-prompt every cycle.
                return .failure(.credentialsUnavailable(credentialsError))
            } catch {
                return .sessionExpired
            }

            guard refreshed.accessToken != accessToken else { return .sessionExpired }
            return await performFetch(accessToken: refreshed.accessToken, allowRetry: false, now: now)
        case .rateLimited(let retryAfter):
            recordRateLimit(retryAfter: retryAfter, now: now)
            return cachedResult(now: now) ?? .failure(.rateLimited(retryAfter: retryAfter))
        case .offline:
            recordAttempt(now: now)
            return cachedResult(now: now) ?? .failure(.offline)
        case .unexpectedStatus(let code):
            recordAttempt(now: now)
            return cachedResult(now: now) ?? .failure(.serverError(code))
        case .decodingFailed:
            recordAttempt(now: now)
            return cachedResult(now: now) ?? .failure(.decodingFailed)
        case .networkError, .notHTTP:
            recordAttempt(now: now)
            return cachedResult(now: now) ?? .failure(.networkError)
        }
    }

    private func recordSuccess(snapshot: UsageSnapshot, now: Date) {
        consecutiveRateLimits = 0
        nextAllowedFetch = now.addingTimeInterval(Self.minimumFetchInterval)
        persist(snapshot: snapshot, fetchedAt: now)
    }

    private func recordAttempt(now: Date) {
        nextAllowedFetch = now.addingTimeInterval(Self.minimumFetchInterval)
    }

    private func recordRateLimit(retryAfter: TimeInterval?, now: Date) {
        let stepIndex: Int = min(consecutiveRateLimits, Self.backoffSteps.count - 1)
        let backoffDuration: TimeInterval = Self.backoffSteps[stepIndex]
        consecutiveRateLimits += 1

        var deadline: Date = now.addingTimeInterval(backoffDuration)
        if let retryAfter, retryAfter > 0 {
            let retryDeadline: Date = now.addingTimeInterval(retryAfter)
            if retryDeadline > deadline { deadline = retryDeadline }
        }
        nextAllowedFetch = deadline
    }

    private func persist(snapshot: UsageSnapshot, fetchedAt: Date) {
        let cached: CachedUsage = CachedUsage(snapshot: snapshot, fetchedAt: fetchedAt)
        do {
            let data: Data = try Self.cacheEncoder().encode(cached)
            userDefaults.set(data, forKey: Self.cacheKey)
        } catch {
            Self.logger.error("failed to encode usage cache: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadCached() -> CachedUsage? {
        guard let data: Data = userDefaults.data(forKey: Self.cacheKey) else { return nil }
        return try? Self.cacheDecoder().decode(CachedUsage.self, from: data)
    }

    private func cachedResult(now: Date) -> UsageRepositoryResult? {
        guard let cached: CachedUsage = loadCached() else { return nil }
        let age: TimeInterval = now.timeIntervalSince(cached.fetchedAt)
        guard age > Self.freshnessTTL else { return .fresh(cached.snapshot) }
        return .stale(cached.snapshot, age: age)
    }

    /// Round-trips our own cache entries as raw epoch seconds (a `Double`), not an ISO8601
    /// string — any string-formatted strategy truncates `Date`'s sub-millisecond precision and
    /// breaks `Equatable` comparisons after reload. `.secondsSince1970` is lossless here.
    private static func cacheEncoder() -> JSONEncoder {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func cacheDecoder() -> JSONDecoder {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
