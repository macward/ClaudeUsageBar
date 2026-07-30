import Foundation
import OSLog

// MARK: - Errors

internal enum UsageAPIProbeError: Error, CustomStringConvertible {
    case notHTTP
    case unauthorized
    case rateLimited
    case unexpectedStatus(Int, String)
    case decodingFailed(String)

    internal var description: String {
        switch self {
        case .notHTTP:
            return "la respuesta no es HTTPURLResponse"
        case .unauthorized:
            return "401 — token caducado o sin scope user:profile"
        case .rateLimited:
            return "429 rate_limit_error — bucket agotado (¿falta el User-Agent de claude-code?)"
        case .unexpectedStatus(let code, let body):
            return "HTTP \(code) — \(body.prefix(200))"
        case .decodingFailed(let reason):
            return "no se pudo decodificar: \(reason)"
        }
    }
}

// MARK: - Response Model

/// Decodes only the stable-looking subset. Every field is optional on purpose: this is an
/// undocumented endpoint that ships internal feature-flag keys (`tangelo`, `seven_day_omelette`,
/// `iguana_necktie`…) which will come and go. Missing keys must never fail the whole decode.
internal struct UsageSnapshot: Decodable, Sendable {

    internal struct Window: Decodable, Sendable {
        internal let utilization: Double?
        internal let resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    internal struct Limit: Decodable, Sendable {
        internal let kind: String?
        internal let group: String?
        internal let percent: Double?
        internal let severity: String?
        internal let resetsAt: Date?
        internal let isActive: Bool?

        private enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }
    }

    internal let fiveHour: Window?
    internal let sevenDay: Window?
    internal let limits: [Limit]?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }
}

// MARK: - Probe

/// P2: can a sandboxed app reach the undocumented usage endpoint and decode it?
internal struct UsageAPIProbe {

    private static let endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader: String = "oauth-2025-04-20"

    /// OPEN QUESTION: a sandboxed app cannot shell out to `claude --version`, so this is pinned.
    /// If Anthropic ever gates on a minimum version, this constant becomes a maintenance burden.
    private static let claudeCodeVersion: String = "2.1.220"

    private static let logger: Logger = Logger(subsystem: "com.maxward.ClaudeUsageBar", category: "UsageAPIProbe")

    private let session: URLSession

    internal init(session: URLSession = .shared) {
        self.session = session
    }

    internal func fetch(accessToken: String) async throws -> (snapshot: UsageSnapshot, rawBody: String) {
        var request: URLRequest = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(Self.claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw UsageAPIProbeError.notHTTP }
        let body: String = String(data: data, encoding: .utf8) ?? "<binario>"
        Self.logger.info("usage endpoint status \(http.statusCode, privacy: .public)")

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw UsageAPIProbeError.unauthorized
        case 429:
            throw UsageAPIProbeError.rateLimited
        default:
            throw UsageAPIProbeError.unexpectedStatus(http.statusCode, body)
        }

        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeFractionalISO8601)

        do {
            let snapshot: UsageSnapshot = try decoder.decode(UsageSnapshot.self, from: data)
            return (snapshot, body)
        } catch {
            throw UsageAPIProbeError.decodingFailed(String(describing: error))
        }
    }

    // MARK: - Private Methods

    /// Timestamps arrive as `2026-07-30T06:29:59.393695+00:00` — 6 fractional digits, which
    /// `.iso8601` rejects outright.
    @Sendable
    nonisolated private static func decodeFractionalISO8601(_ decoder: any Decoder) throws -> Date {
        let raw: String = try decoder.singleValueContainer().decode(String.self)
        let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }

        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "timestamp ilegible: \(raw)")
        )
    }
}
