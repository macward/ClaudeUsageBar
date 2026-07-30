import Foundation
@testable import ClaudeUsageBar

/// Returns one queued result per call, repeating the last one once the queue is drained. Needed
/// for the 401-retry tests, where the repository reads credentials twice and the second read
/// must differ from (or match) the first.
internal final class SequencedCredentialsService: ClaudeCodeCredentialsServiceProtocol, @unchecked Sendable {

    private var results: [Result<ClaudeCodeCredentials, ClaudeCodeCredentialsError>]

    /// Every read is a potential SecurityAgent prompt in the real service, so tests that assert
    /// "the app never re-prompts on its own" assert on this counter.
    internal private(set) var callCount: Int = 0

    internal init(results: [Result<ClaudeCodeCredentials, ClaudeCodeCredentialsError>]) {
        self.results = results
    }

    internal func readCredentials() async throws -> ClaudeCodeCredentials {
        callCount += 1
        guard !results.isEmpty else { throw ClaudeCodeCredentialsError.itemNotFound }
        let result: Result<ClaudeCodeCredentials, ClaudeCodeCredentialsError> = results.count > 1
            ? results.removeFirst()
            : results[0]
        return try result.get()
    }
}
