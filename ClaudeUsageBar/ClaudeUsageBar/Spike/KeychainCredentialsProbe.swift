import Foundation
import OSLog
import Security

// MARK: - Errors

internal enum KeychainProbeError: Error, CustomStringConvertible {
    case itemNotFound
    case interactionNotAllowed
    case missingAuthorization
    case unexpectedStatus(OSStatus)
    case malformedPayload
    case missingOAuthSection

    internal var description: String {
        switch self {
        case .itemNotFound:
            return "errSecItemNotFound (-25300) — el item existe en el login keychain pero el sandbox no lo ve"
        case .interactionNotAllowed:
            return "errSecInteractionNotAllowed (-25308) — requiere UI de autorización no disponible"
        case .missingAuthorization:
            return "errSecMissingEntitlement / authorization denied — la ACL del item no incluye a esta app"
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

// MARK: - Credentials

/// Only the fields the spike needs. Deliberately does not retain the refresh token.
internal struct ClaudeCodeCredentials: Sendable {
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

// MARK: - Probe

/// P1: can a sandboxed, hardened-runtime app read the item that the `claude` CLI wrote?
internal struct KeychainCredentialsProbe {

    private static let service: String = "Claude Code-credentials"
    private static let logger: Logger = Logger(subsystem: "com.maxward.ClaudeUsageBar", category: "KeychainProbe")

    internal func read() throws -> ClaudeCodeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw KeychainProbeError.itemNotFound
        case errSecInteractionNotAllowed:
            throw KeychainProbeError.interactionNotAllowed
        case errSecMissingEntitlement, errSecAuthFailed:
            throw KeychainProbeError.missingAuthorization
        default:
            throw KeychainProbeError.unexpectedStatus(status)
        }

        guard let data = item as? Data else { throw KeychainProbeError.malformedPayload }

        Self.logger.info("keychain item read, \(data.count, privacy: .public) bytes")
        return try Self.decode(data)
    }

    // MARK: - Private Methods

    private static func decode(_ data: Data) throws -> ClaudeCodeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeychainProbeError.malformedPayload
        }
        guard
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw KeychainProbeError.missingOAuthSection
        }

        // `expiresAt` is epoch milliseconds.
        let expiresAtMillis: Double = (oauth["expiresAt"] as? Double) ?? 0
        return ClaudeCodeCredentials(
            accessToken: token,
            expiresAt: Date(timeIntervalSince1970: expiresAtMillis / 1000),
            subscriptionType: (oauth["subscriptionType"] as? String) ?? "unknown",
            scopes: (oauth["scopes"] as? [String]) ?? []
        )
    }
}
