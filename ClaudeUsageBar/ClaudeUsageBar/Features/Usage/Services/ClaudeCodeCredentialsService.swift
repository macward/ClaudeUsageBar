import Foundation
import Security

internal nonisolated enum ClaudeCodeCredentialsError: Error, CustomStringConvertible, Sendable, Equatable {
    case itemNotFound
    case interactionNotAllowed
    case missingAuthorization
    case userDeniedAccess
    case unexpectedStatus(OSStatus)
    case malformedPayload
    case missingOAuthSection

    /// The three ways the Keychain says "you are not authorized to read this item". They share
    /// one property that matters to the app: retrying triggers a fresh SecurityAgent prompt, so
    /// an automatic retry loop would prompt the user over and over. Only an explicit user action
    /// may retry these.
    internal var isAuthorizationFailure: Bool {
        switch self {
        case .interactionNotAllowed, .missingAuthorization, .userDeniedAccess:
            return true
        case .itemNotFound, .unexpectedStatus, .malformedPayload, .missingOAuthSection:
            return false
        }
    }

    internal var description: String {
        switch self {
        case .itemNotFound:
            return "errSecItemNotFound (-25300) — no hay sesión de Claude Code CLI en este Mac"
        case .interactionNotAllowed:
            return "errSecInteractionNotAllowed (-25308) — requiere UI de autorización no disponible"
        case .missingAuthorization:
            return "acceso denegado — la ACL del item Keychain no incluye a esta app"
        case .userDeniedAccess:
            return "errSecUserCanceled (-128) — el usuario rechazó el prompt de SecurityAgent"
        case .unexpectedStatus(let status):
            let message: String = SecCopyErrorMessageString(status, nil) as String? ?? "sin descripción"
            return "OSStatus \(status) — \(message)"
        case .malformedPayload:
            return "el payload del keychain no es JSON UTF-8 válido"
        case .missingOAuthSection:
            return "JSON válido pero sin claudeAiOauth.accessToken"
        }
    }
}

/// Only the fields the app needs. Deliberately does not retain the refresh token, and
/// never refreshes — refreshing would rotate the token and break the CLI's own session.
internal nonisolated struct ClaudeCodeCredentials: Sendable {
    internal let accessToken: String
    internal let expiresAt: Date
    internal let subscriptionType: String
    internal let scopes: [String]

    internal var isExpired: Bool { expiresAt <= Date() }

    /// Never log or render the token itself — only enough to prove we read the right thing.
    internal var redactedToken: String {
        let prefix: String = String(accessToken.prefix(14))
        return "\(prefix)…(\(accessToken.count) chars)"
    }
}

nonisolated extension ClaudeCodeCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    internal var description: String {
        "ClaudeCodeCredentials(token: \(redactedToken), subscriptionType: \(subscriptionType), expiresAt: \(expiresAt))"
    }

    internal var debugDescription: String { description }
}

/// Reads the OAuth token Claude Code's CLI already stored in the Keychain. Read-only: this
/// service never writes, refreshes, or rotates the item — that's the CLI's job alone.
internal nonisolated protocol ClaudeCodeCredentialsServiceProtocol: Sendable {
    func readCredentials() async throws -> ClaudeCodeCredentials
}

internal nonisolated struct ClaudeCodeCredentialsService: ClaudeCodeCredentialsServiceProtocol {

    private static let service: String = "Claude Code-credentials"

    internal init() {}

    /// `SecItemCopyMatching` blocks until the user answers the SecurityAgent prompt on first
    /// access, so this always runs off the caller's actor via `Task.detached`.
    internal func readCredentials() async throws -> ClaudeCodeCredentials {
        try await Task.detached(priority: .userInitiated) {
            try Self.readCredentialsBlocking()
        }.value
    }

    // MARK: - Private Methods

    private static func readCredentialsBlocking() throws -> ClaudeCodeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw ClaudeCodeCredentialsError.itemNotFound
        case errSecInteractionNotAllowed:
            throw ClaudeCodeCredentialsError.interactionNotAllowed
        case errSecMissingEntitlement, errSecAuthFailed:
            throw ClaudeCodeCredentialsError.missingAuthorization
        case errSecUserCanceled:
            throw ClaudeCodeCredentialsError.userDeniedAccess
        default:
            throw ClaudeCodeCredentialsError.unexpectedStatus(status)
        }

        guard let data = item as? Data else { throw ClaudeCodeCredentialsError.malformedPayload }
        return try decode(data)
    }

    internal static func decode(_ data: Data) throws -> ClaudeCodeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCodeCredentialsError.malformedPayload
        }
        guard
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw ClaudeCodeCredentialsError.missingOAuthSection
        }

        // `expiresAt` is epoch milliseconds, not seconds. A missing/non-numeric value is a
        // malformed payload, not "already expired" — don't paper over it with a 0 default.
        guard let expiresAtMillis: Double = oauth["expiresAt"] as? Double else {
            throw ClaudeCodeCredentialsError.malformedPayload
        }
        return ClaudeCodeCredentials(
            accessToken: token,
            expiresAt: Date(timeIntervalSince1970: expiresAtMillis / 1000),
            subscriptionType: (oauth["subscriptionType"] as? String) ?? "unknown",
            scopes: (oauth["scopes"] as? [String]) ?? []
        )
    }
}
