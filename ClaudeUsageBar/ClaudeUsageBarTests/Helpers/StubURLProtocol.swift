import Foundation

/// Intercepts requests made through a `URLSession` configured with this protocol class,
/// so service tests never touch the network. Set `handler` before making the request and
/// clear it afterwards to avoid leaking state between tests.
internal final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    // Test-only global: each test sets it before making its request and clears it in a `defer`,
    // so tests never run this protocol concurrently against different handlers.
    nonisolated(unsafe) internal static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override internal class func canInit(with request: URLRequest) -> Bool { true }

    override internal class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override internal func startLoading() {
        guard let handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override internal func stopLoading() {}
}
