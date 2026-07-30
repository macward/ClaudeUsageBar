import Foundation
import Testing
@testable import ClaudeUsageBar

// `.serialized`: every test in this suite drives the same shared `StubURLProtocol.handler`,
// so they must not run concurrently against each other.
@Suite("UsageAPIService error mapping", .serialized)
struct UsageAPIServiceTests {

    @Test("A 200 response with the real fixture decodes to a populated UsageSnapshot")
    func decodesSuccessfulResponse() async throws {
        let fixture: Data = try FixtureLoader.data(named: "usage-full")
        StubURLProtocol.handler = { request in
            let response: HTTPURLResponse = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, fixture)
        }
        defer { StubURLProtocol.handler = nil }

        let service: UsageAPIService = UsageAPIService(session: Self.stubbedSession())
        let snapshot: UsageSnapshot = try await service.fetchUsage(accessToken: "sk-ant-oat01-test")

        #expect(snapshot.fiveHour?.utilization == 55.0)
        #expect(snapshot.limits?.count == 2)
    }

    @Test("401 maps to unauthorized")
    func mapsUnauthorized() async {
        StubURLProtocol.handler = { request in
            let response: HTTPURLResponse = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.handler = nil }

        let service: UsageAPIService = UsageAPIService(session: Self.stubbedSession())
        await #expect(throws: UsageAPIServiceError.unauthorized) {
            try await service.fetchUsage(accessToken: "sk-ant-oat01-test")
        }
    }

    @Test("429 with Retry-After: 600 produces rateLimited(retryAfter: 600)")
    func mapsRateLimitedWithRetryAfter() async {
        StubURLProtocol.handler = { request in
            let response: HTTPURLResponse = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "600"]
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.handler = nil }

        let service: UsageAPIService = UsageAPIService(session: Self.stubbedSession())
        await #expect(throws: UsageAPIServiceError.rateLimited(retryAfter: 600)) {
            try await service.fetchUsage(accessToken: "sk-ant-oat01-test")
        }
    }

    @Test("429 without Retry-After produces rateLimited(retryAfter: nil)")
    func mapsRateLimitedWithoutRetryAfter() async {
        StubURLProtocol.handler = { request in
            let response: HTTPURLResponse = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.handler = nil }

        let service: UsageAPIService = UsageAPIService(session: Self.stubbedSession())
        await #expect(throws: UsageAPIServiceError.rateLimited(retryAfter: nil)) {
            try await service.fetchUsage(accessToken: "sk-ant-oat01-test")
        }
    }

    @Test("A URLError(.notConnectedToInternet) maps to offline, not a generic error")
    func mapsOfflineFromURLError() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { StubURLProtocol.handler = nil }

        let service: UsageAPIService = UsageAPIService(session: Self.stubbedSession())
        await #expect(throws: UsageAPIServiceError.offline) {
            try await service.fetchUsage(accessToken: "sk-ant-oat01-test")
        }
    }

    @Test("An unrelated URLError maps to the generic networkError case")
    func mapsUnrelatedURLErrorToNetworkError() async {
        StubURLProtocol.handler = { _ in throw URLError(.badServerResponse) }
        defer { StubURLProtocol.handler = nil }

        let service: UsageAPIService = UsageAPIService(session: Self.stubbedSession())
        await #expect(throws: UsageAPIServiceError.networkError) {
            try await service.fetchUsage(accessToken: "sk-ant-oat01-test")
        }
    }

    // MARK: - Private Methods

    private static func stubbedSession() -> URLSession {
        let configuration: URLSessionConfiguration = .ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
