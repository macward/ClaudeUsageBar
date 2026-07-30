import Foundation

internal nonisolated enum UsageAPIServiceError: Error, CustomStringConvertible, Sendable, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case unexpectedStatus(Int)
    case decodingFailed
    case networkError
    case notHTTP

    internal var description: String {
        switch self {
        case .unauthorized:
            return "401 — token caducado o sin scope user:profile"
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "429 rate_limit_error — sin Retry-After" }
            return "429 rate_limit_error — reintentar en \(Int(retryAfter))s"
        case .offline:
            return "sin conexión de red"
        case .unexpectedStatus(let code):
            return "HTTP inesperado \(code)"
        case .decodingFailed:
            return "no se pudo decodificar la respuesta"
        case .networkError:
            return "error de red no clasificado"
        case .notHTTP:
            return "la respuesta no es HTTPURLResponse"
        }
    }
}

internal nonisolated protocol UsageAPIServiceProtocol: Sendable {
    func fetchUsage(accessToken: String) async throws -> UsageSnapshot
}

internal nonisolated struct UsageAPIService: UsageAPIServiceProtocol {

    private static let endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader: String = "oauth-2025-04-20"

    /// Único punto de la app donde vive esta versión. Bump manual cuando el endpoint empiece a
    /// devolver 429 persistentes durante horas que no ceden con backoff normal — ese es el
    /// síntoma típico de un User-Agent obsoleto. Una app sandboxed no puede shellear
    /// `claude --version`, así que este valor no se puede derivar en runtime.
    private static let claudeCodeVersion: String = "2.1.220"

    private let session: URLSession

    internal init(session: URLSession = .shared) {
        self.session = session
    }

    internal func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        var request: URLRequest = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(Self.claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut:
                throw UsageAPIServiceError.offline
            default:
                throw UsageAPIServiceError.networkError
            }
        } catch {
            throw UsageAPIServiceError.networkError
        }

        guard let http = response as? HTTPURLResponse else { throw UsageAPIServiceError.notHTTP }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw UsageAPIServiceError.unauthorized
        case 429:
            throw UsageAPIServiceError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default:
            throw UsageAPIServiceError.unexpectedStatus(http.statusCode)
        }

        do {
            return try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)
        } catch {
            throw UsageAPIServiceError.decodingFailed
        }
    }

    // MARK: - Private Methods

    /// Only handles the delay-seconds form (`Retry-After: 600`), not the RFC 7231 HTTP-date
    /// form — this is Anthropic's own endpoint and it only ever emits delay-seconds.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(raw)
    }
}
