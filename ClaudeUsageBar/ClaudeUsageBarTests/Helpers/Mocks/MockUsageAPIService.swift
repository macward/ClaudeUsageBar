import Foundation
@testable import ClaudeUsageBar

internal nonisolated struct MockUsageAPIService: UsageAPIServiceProtocol {

    private let result: Result<UsageSnapshot, UsageAPIServiceError>

    internal init(result: Result<UsageSnapshot, UsageAPIServiceError>) {
        self.result = result
    }

    internal func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        try result.get()
    }
}
