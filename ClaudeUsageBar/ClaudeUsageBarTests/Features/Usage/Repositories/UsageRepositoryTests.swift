import Foundation
import Testing
@testable import ClaudeUsageBar

@MainActor
@Suite("UsageRepository policy")
struct UsageRepositoryTests {

    @Test("A successful fetch resets the 429 backoff to the base 180s interval")
    func successResetsBackoff() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [
            .failure(.rateLimited(retryAfter: nil)),
            .failure(.rateLimited(retryAfter: nil)),
            .success(Self.sampleSnapshot())
        ])
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: apiService,
            userDefaults: defaults
        )
        let start: Date = Date()

        // Two 429s escalate the backoff to the 6-minute step.
        _ = await repository.refresh(now: start)
        _ = await repository.refresh(now: repository.nextAllowedFetch)

        let successAttemptTime: Date = repository.nextAllowedFetch
        let result: UsageRepositoryResult = await repository.refresh(now: successAttemptTime)
        guard case .fresh = result else { Issue.record("expected .fresh, got \(result)"); return }

        // Base interval (180s), not a multi-minute backoff step, follows the success.
        let afterSuccess: Date = repository.nextAllowedFetch
        #expect(abs(afterSuccess.timeIntervalSince(successAttemptTime) - 180) < 1)
    }

    @Test("Three consecutive 429s escalate the backoff 3 → 6 → 12 minutes")
    func rateLimitEscalates() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [
            .failure(.rateLimited(retryAfter: nil)),
            .failure(.rateLimited(retryAfter: nil)),
            .failure(.rateLimited(retryAfter: nil)),
            .failure(.rateLimited(retryAfter: nil))
        ])
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: apiService,
            userDefaults: defaults
        )
        let start: Date = Date()

        _ = await repository.refresh(now: start)
        let firstDeadline: Date = repository.nextAllowedFetch
        #expect(abs(firstDeadline.timeIntervalSince(start) - 180) < 1)

        _ = await repository.refresh(now: firstDeadline)
        let secondDeadline: Date = repository.nextAllowedFetch
        #expect(abs(secondDeadline.timeIntervalSince(firstDeadline) - 360) < 1)

        _ = await repository.refresh(now: secondDeadline)
        let thirdDeadline: Date = repository.nextAllowedFetch
        #expect(abs(thirdDeadline.timeIntervalSince(secondDeadline) - 720) < 1)

        _ = await repository.refresh(now: thirdDeadline)
        let fourthDeadline: Date = repository.nextAllowedFetch
        // 15 min is the cap: the 4th consecutive 429 lands on 900s, not a further escalation.
        #expect(abs(fourthDeadline.timeIntervalSince(thirdDeadline) - 900) < 1)
    }

    @Test("A Retry-After longer than the computed backoff step wins")
    func retryAfterWinsWhenLarger() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [
            .failure(.rateLimited(retryAfter: 3600))
        ])
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: apiService,
            userDefaults: defaults
        )
        let start: Date = Date()

        _ = await repository.refresh(now: start)

        // The base 429 step here would be 180s; Retry-After: 3600 must win instead.
        #expect(abs(repository.nextAllowedFetch.timeIntervalSince(start) - 3600) < 1)
    }

    @Test("A call before nextAllowedFetch returns throttled without touching either service")
    func earlyCallIsThrottledWithoutTouchingServices() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())])
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: apiService,
            userDefaults: defaults
        )
        let start: Date = Date()

        _ = await repository.refresh(now: start)
        #expect(apiService.callCount == 1)

        let result: UsageRepositoryResult = await repository.refresh(now: start.addingTimeInterval(1))

        #expect(apiService.callCount == 1)
        guard case .throttled(let until) = result else { Issue.record("expected .throttled, got \(result)"); return }
        #expect(until == repository.nextAllowedFetch)
    }

    @Test("A 401 with an identical re-read token means the session is expired, no retry")
    func unauthorizedWithIdenticalTokenIsSessionExpired() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let credentials: ClaudeCodeCredentials = Self.validCredentials(token: "sk-ant-oat01-same")
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.failure(.unauthorized)])
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(credentials)),
            apiService: apiService,
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh()

        #expect(result == .sessionExpired)
        #expect(apiService.callCount == 1)
    }

    @Test("A denied Keychain read on the 401 re-read surfaces as credentialsUnavailable, not sessionExpired")
    func unauthorizedThenDeniedReReadSurfacesAuthorizationFailure() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(results: [
            .success(Self.validCredentials(token: "sk-ant-oat01-old")),
            .failure(.userDeniedAccess)
        ])
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.failure(.unauthorized)])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh()

        // Collapsing this into .sessionExpired would hide the denial from the ViewModel's
        // authorization gate, leaving the polling loop alive to re-prompt every cycle.
        #expect(result == .failure(.credentialsUnavailable(.userDeniedAccess)))
    }

    @Test("A pre-flight-expired token returns sessionExpired without touching the network")
    func preFlightExpiredReturnsSessionExpiredWithoutNetworkCall() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let expiredCredentials: ClaudeCodeCredentials = ClaudeCodeCredentials(
            accessToken: "sk-ant-oat01-expired",
            expiresAt: Self.referenceDate.addingTimeInterval(-60),
            subscriptionType: "max",
            scopes: []
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())])
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(expiredCredentials)),
            apiService: apiService,
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh(now: Self.referenceDate)

        #expect(result == .sessionExpired)
        #expect(apiService.callCount == 0)
    }

    @Test("A pre-flight-expired token still arms the fetch interval")
    func preFlightExpiredAdvancesNextAllowedFetch() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let expiredCredentials: ClaudeCodeCredentials = ClaudeCodeCredentials(
            accessToken: "sk-ant-oat01-expired",
            expiresAt: Self.referenceDate.addingTimeInterval(-60),
            subscriptionType: "max",
            scopes: []
        )
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(expiredCredentials)),
            apiService: SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())]),
            userDefaults: defaults
        )

        _ = await repository.refresh(now: Self.referenceDate)

        // Leaving the deadline in the past is what let the polling loop — which sleeps until
        // exactly this instant — collapse to its floor and re-read the Keychain in a tight loop
        // for as long as the token stayed expired. A dead session gets the longer interval rather
        // than the baseline 180s: it re-reads the Keychain on every attempt, so each one is a
        // possible SecurityAgent prompt.
        #expect(abs(repository.nextAllowedFetch.timeIntervalSince(Self.referenceDate) - 900) < 1)
    }

    @Test("A Keychain read failure still arms the fetch interval")
    func credentialsFailureAdvancesNextAllowedFetch() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .failure(.itemNotFound)),
            apiService: SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())]),
            userDefaults: defaults
        )

        _ = await repository.refresh(now: Self.referenceDate)

        #expect(abs(repository.nextAllowedFetch.timeIntervalSince(Self.referenceDate) - 180) < 1)
    }

    @Test("The authorization retry ignores the interval a denial just armed")
    func retryIgnoringThrottleBypassesTheArmedInterval() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.failure(.userDeniedAccess), .success(Self.validCredentials())]
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )

        let denied: UsageRepositoryResult = await repository.refresh(now: Self.referenceDate)
        #expect(denied == .failure(.credentialsUnavailable(.userDeniedAccess)))

        // An ordinary refresh one second later is inside the interval the denial just armed, so it
        // would never re-read the Keychain — which is the whole point of pressing "Reintentar".
        let retried: UsageRepositoryResult = await repository.retryIgnoringThrottle(
            now: Self.referenceDate.addingTimeInterval(1)
        )

        guard case .fresh = retried else { Issue.record("expected .fresh, got \(retried)"); return }
        #expect(apiService.callCount == 1)
    }

    @Test("Session-expired states take priority over a stale cached snapshot, not masked by it")
    func sessionExpiredIsNotMaskedByStaleCache() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        Self.seedCache(defaults, snapshot: Self.sampleSnapshot(), fetchedAt: Self.referenceDate.addingTimeInterval(-30))
        let expiredCredentials: ClaudeCodeCredentials = ClaudeCodeCredentials(
            accessToken: "sk-ant-oat01-expired",
            expiresAt: Self.referenceDate.addingTimeInterval(-60),
            subscriptionType: "max",
            scopes: []
        )
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(expiredCredentials)),
            apiService: SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())]),
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh(now: Self.referenceDate)

        // A stale-but-plausible number would mask the fact that re-authentication is needed —
        // sessionExpired must win even though a cached snapshot exists.
        #expect(result == .sessionExpired)
    }

    @Test("A Keychain read failure produces credentialsUnavailable, not a cached fallback")
    func credentialsUnavailableFailsWithoutCacheFallback() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        Self.seedCache(defaults, snapshot: Self.sampleSnapshot(), fetchedAt: Self.referenceDate.addingTimeInterval(-30))
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .failure(.itemNotFound)),
            apiService: SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())]),
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh(now: Self.referenceDate)

        #expect(result == .failure(.credentialsUnavailable(.itemNotFound)))
    }

    @Test("Offline with no cached snapshot yet produces failure(.offline), not a crash or nil")
    func offlineWithEmptyCacheReturnsFailure() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: SequencedUsageAPIService(results: [.failure(.offline)]),
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh(now: Self.referenceDate)

        #expect(result == .failure(.offline))
    }

    @Test("A 401 with a genuinely new re-read token triggers exactly one retry")
    func unauthorizedWithNewTokenRetriesOnce() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let snapshot: UsageSnapshot = Self.sampleSnapshot()
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(results: [
            .success(Self.validCredentials(token: "sk-ant-oat01-old")),
            .success(Self.validCredentials(token: "sk-ant-oat01-new"))
        ])
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [
            .failure(.unauthorized),
            .success(snapshot)
        ])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh()

        #expect(result == .fresh(snapshot))
        #expect(apiService.callCount == 2)
    }

    @Test("An 11-minute-old cached snapshot is presented as stale, with its age")
    func staleCacheAfterTenMinuteTTL() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let snapshot: UsageSnapshot = Self.sampleSnapshot()
        let now: Date = Date()
        Self.seedCache(defaults, snapshot: snapshot, fetchedAt: now.addingTimeInterval(-11 * 60))

        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: SequencedUsageAPIService(results: [.failure(.offline)]),
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh(now: now)

        guard case .stale(let cached, let age) = result else { Issue.record("expected .stale, got \(result)"); return }
        #expect(cached == snapshot)
        #expect(abs(age - 11 * 60) < 1)
    }

    @Test("A previously cached snapshot is available at startup, before any fetch")
    func cachedSnapshotAvailableAtStartup() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let snapshot: UsageSnapshot = Self.sampleSnapshot()
        let now: Date = Date()
        Self.seedCache(defaults, snapshot: snapshot, fetchedAt: now.addingTimeInterval(-60))

        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: SequencedUsageAPIService(results: [.failure(.offline)]),
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh(now: now)

        #expect(result == .fresh(snapshot))
    }

    @Test("The cached snapshot survives a save/load round trip through UserDefaults")
    func cacheSurvivesRoundTrip() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let snapshot: UsageSnapshot = Self.sampleSnapshot()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(snapshot)])
        let firstRepository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: apiService,
            userDefaults: defaults
        )
        _ = await firstRepository.refresh()

        // A brand-new repository instance reading the same UserDefaults must see the cache.
        let secondRepository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: SequencedUsageAPIService(results: [.failure(.offline)]),
            userDefaults: defaults
        )
        let result: UsageRepositoryResult = await secondRepository.refresh(now: Date().addingTimeInterval(200))

        #expect(result == .fresh(snapshot))
    }

    @Test("No token field is ever present in the cached UserDefaults payload")
    func cacheNeverContainsTheToken() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let secretToken: String = "sk-ant-oat01-super-secret-value"
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())])
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials(token: secretToken))),
            apiService: apiService,
            userDefaults: defaults
        )
        _ = await repository.refresh()

        let cachedData: Data = try #require(defaults.data(forKey: "com.maxward.ClaudeUsageBar.cachedUsageSnapshot"))
        let cachedString: String = String(decoding: cachedData, as: UTF8.self)
        #expect(!cachedString.contains(secretToken))
    }

    @Test("A still-valid token is reused from memory, so repeated fetches read the Keychain once")
    func validTokenIsReadFromTheKeychainOnlyOnce() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.success(Self.validCredentials())]
        )
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())]),
            userDefaults: defaults
        )

        // Three fetches spaced past the 180s interval — the same cadence the polling loop runs at.
        for step: Int in 0..<3 {
            _ = await repository.refresh(now: Self.referenceDate.addingTimeInterval(Double(step) * 200))
        }

        // Every Keychain read is a possible SecurityAgent prompt: `claude` rewrites its item with
        // `security add-generic-password -U`, which drops the "Permitir siempre" grant, so reading
        // once per poll turned each rewrite into a prompt within three minutes.
        #expect(credentialsService.callCount == 1)
    }

    @Test("A token within five minutes of expiry is re-read rather than reused")
    func tokenNearExpiryIsReRead() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(results: [
            .success(ClaudeCodeCredentials(
                accessToken: "sk-ant-oat01-almost-done",
                expiresAt: Self.referenceDate.addingTimeInterval(400),
                subscriptionType: "max",
                scopes: []
            )),
            .success(Self.validCredentials(token: "sk-ant-oat01-rotated"))
        ])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())]),
            userDefaults: defaults
        )

        _ = await repository.refresh(now: Self.referenceDate)
        // 200s later the cached token has 200s of life left — inside the 300s margin, so it must
        // be swapped before the API starts answering 401 rather than after.
        _ = await repository.refresh(now: Self.referenceDate.addingTimeInterval(200))

        #expect(credentialsService.callCount == 2)
    }

    @Test("The authorization retry always re-reads the Keychain, never the in-memory token")
    func authorizationRetryDiscardsTheInMemoryToken() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.success(Self.validCredentials())]
        )
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: SequencedUsageAPIService(results: [.success(Self.sampleSnapshot())]),
            userDefaults: defaults
        )

        _ = await repository.refresh(now: Self.referenceDate)
        #expect(credentialsService.callCount == 1)

        // Reusing the in-memory copy here would make "Reintentar" a no-op against the exact
        // failure it exists for: the Keychain refusing the read.
        _ = await repository.retryIgnoringThrottle(now: Self.referenceDate.addingTimeInterval(1))

        #expect(credentialsService.callCount == 2)
    }

    @Test("A 401 re-reads the Keychain even with a token still cached in memory")
    func unauthorizedBypassesTheInMemoryToken() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(results: [
            .success(Self.validCredentials(token: "sk-ant-oat01-old")),
            .success(Self.validCredentials(token: "sk-ant-oat01-new"))
        ])
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [
            .failure(.unauthorized),
            .success(Self.sampleSnapshot())
        ])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh(now: Self.referenceDate)

        // The token in memory is exactly the one the server just rejected, so rotation can only be
        // picked up by going back to the Keychain.
        guard case .fresh = result else { Issue.record("expected .fresh, got \(result)"); return }
        #expect(credentialsService.callCount == 2)
    }

    @Test("A dead session backs off to 15 minutes, not the baseline interval")
    func sessionExpiredArmsTheLongerInterval() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let repository: UsageRepository = UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: SequencedUsageAPIService(results: [.failure(.unauthorized)]),
            userDefaults: defaults
        )

        let result: UsageRepositoryResult = await repository.refresh(now: Self.referenceDate)

        #expect(result == .sessionExpired)
        // This state re-reads the Keychain on every attempt, so at the baseline 180s it would be a
        // possible prompt every three minutes for as long as the user stayed logged out.
        #expect(abs(repository.nextAllowedFetch.timeIntervalSince(Self.referenceDate) - 900) < 1)
    }

    // MARK: - Private Helpers

    private static func freshDefaults() -> UserDefaults {
        let suiteName: String = "com.maxward.ClaudeUsageBarTests.\(UUID().uuidString)"
        let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// A fixed, whole-second epoch instant. Deliberately not derived from `Date()`: the cache
    /// round-trips dates through `.secondsSince1970`, and a sub-second `Date()` value picks up
    /// genuine ULP-level rounding noise converting between the reference-date and 1970 epochs,
    /// which then fails exact `Equatable` comparisons that have nothing to do with the policy
    /// under test. A whole-second value round-trips exactly.
    private static let referenceDate: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private static func validCredentials(token: String = "sk-ant-oat01-token") -> ClaudeCodeCredentials {
        ClaudeCodeCredentials(
            accessToken: token,
            expiresAt: Self.referenceDate.addingTimeInterval(3600),
            subscriptionType: "max",
            scopes: []
        )
    }

    private static func sampleSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageSnapshot.Window(utilization: 42, resetsAt: Self.referenceDate.addingTimeInterval(3600)),
            sevenDay: nil,
            limits: nil
        )
    }

    private static func seedCache(_ defaults: UserDefaults, snapshot: UsageSnapshot, fetchedAt: Date) {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        struct CachedUsage: Codable {
            let snapshot: UsageSnapshot
            let fetchedAt: Date
        }
        let data: Data = try! encoder.encode(CachedUsage(snapshot: snapshot, fetchedAt: fetchedAt))
        defaults.set(data, forKey: "com.maxward.ClaudeUsageBar.cachedUsageSnapshot")
    }
}
