import Foundation
@testable import ClaudeUsageBar

/// Returns one queued result per call, repeating the last one once the queue is drained. Tracks
/// `callCount` so tests can assert the repository never calls the API service more than once
/// per 401, and that a 429 sequence produces exactly as many attempts as expected.
internal final class SequencedUsageAPIService: UsageAPIServiceProtocol, @unchecked Sendable {

    private var results: [Result<UsageSnapshot, UsageAPIServiceError>]
    internal private(set) var callCount: Int = 0

    internal init(results: [Result<UsageSnapshot, UsageAPIServiceError>]) {
        self.results = results
    }

    internal func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        callCount += 1
        guard !results.isEmpty else { throw UsageAPIServiceError.networkError }
        let result: Result<UsageSnapshot, UsageAPIServiceError> = results.count > 1
            ? results.removeFirst()
            : results[0]
        return try result.get()
    }
}
