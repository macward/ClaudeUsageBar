import Foundation
@testable import ClaudeUsageBar

internal nonisolated struct MockClaudeCodeCredentialsService: ClaudeCodeCredentialsServiceProtocol {

    private let result: Result<ClaudeCodeCredentials, ClaudeCodeCredentialsError>

    internal init(result: Result<ClaudeCodeCredentials, ClaudeCodeCredentialsError>) {
        self.result = result
    }

    internal func readCredentials() async throws -> ClaudeCodeCredentials {
        try result.get()
    }
}
