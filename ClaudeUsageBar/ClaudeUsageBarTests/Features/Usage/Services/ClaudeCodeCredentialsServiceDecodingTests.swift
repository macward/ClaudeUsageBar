import Foundation
import Testing
@testable import ClaudeUsageBar

@Suite("ClaudeCodeCredentialsService decoding")
struct ClaudeCodeCredentialsServiceDecodingTests {

    @Test("Decodes a valid claudeAiOauth payload")
    func decodesValidPayload() throws {
        let json: String = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz",
            "expiresAt": 1785400000000,
            "subscriptionType": "max",
            "scopes": ["user:inference", "user:profile"]
          }
        }
        """
        let credentials: ClaudeCodeCredentials = try ClaudeCodeCredentialsService.decode(Data(json.utf8))

        #expect(credentials.accessToken == "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz")
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.scopes == ["user:inference", "user:profile"])
        #expect(credentials.expiresAt.timeIntervalSince1970 == 1785400000000 / 1000)
    }

    @Test("Throws missingOAuthSection when claudeAiOauth is absent")
    func throwsWhenOAuthSectionMissing() {
        let json: String = #"{ "someOtherKey": true }"#

        #expect(throws: ClaudeCodeCredentialsError.missingOAuthSection) {
            try ClaudeCodeCredentialsService.decode(Data(json.utf8))
        }
    }

    @Test("Throws malformedPayload on corrupted, non-JSON data")
    func throwsOnCorruptedPayload() {
        let data: Data = Data("not json at all {{{".utf8)

        #expect(throws: ClaudeCodeCredentialsError.malformedPayload) {
            try ClaudeCodeCredentialsService.decode(data)
        }
    }

    @Test("Throws malformedPayload when expiresAt is missing, instead of defaulting to epoch 0")
    func throwsWhenExpiresAtMissing() {
        let json: String = #"{ "claudeAiOauth": { "accessToken": "sk-ant-oat01-abc" } }"#

        #expect(throws: ClaudeCodeCredentialsError.malformedPayload) {
            try ClaudeCodeCredentialsService.decode(Data(json.utf8))
        }
    }

    @Test("Description never contains the raw access token")
    func descriptionRedactsToken() throws {
        let json: String = """
        { "claudeAiOauth": { "accessToken": "sk-ant-oat01-secretvalue", "expiresAt": 1785400000000 } }
        """
        let credentials: ClaudeCodeCredentials = try ClaudeCodeCredentialsService.decode(Data(json.utf8))

        #expect(!"\(credentials)".contains(credentials.accessToken))
        #expect(!credentials.debugDescription.contains(credentials.accessToken))
    }
}
