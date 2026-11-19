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
    /// - Parameter allowingUserInteraction: whether macOS may show its SecurityAgent dialog to
    ///   authorize the read. With `false`, a read the user would have to approve fails at once with
    ///   ``ClaudeCodeCredentialsError/interactionNotAllowed`` instead of opening the dialog. Only a
    ///   read the user explicitly asked for (onboarding, "Autorizar") may pass `true`.
    func readCredentials(allowingUserInteraction: Bool) async throws -> ClaudeCodeCredentials
}

internal nonisolated struct ClaudeCodeCredentialsService: ClaudeCodeCredentialsServiceProtocol {

    // MARK: - Properties

    private static let service: String = "Claude Code-credentials"
    private static let securityToolURL: URL = URL(fileURLWithPath: "/usr/bin/security")
    /// `security`'s exit code for `errSecItemNotFound`.
    private static let securityToolItemNotFoundExitCode: Int32 = 44
    /// An automatic read must never hang the polling loop: if `security` has not answered by then it
    /// is waiting on a dialog, so it is killed (which dismisses the dialog) and the read falls back.
    private static let silentSecurityToolTimeout: Duration = .seconds(3)
    /// A read the user asked for may wait on the dialog for as long as they take to answer it.
    private static let interactiveSecurityToolTimeout: Duration = .seconds(120)

    // MARK: - Lifecycle

    internal init() {}

    // MARK: - Public Methods

    /// Reads through `/usr/bin/security` first and only falls back to `SecItemCopyMatching` when
    /// that fails. The CLI creates its item with `security add-generic-password`, so the item's ACL
    /// trusts `/usr/bin/security` and that binary reads it silently, every time, even after the CLI
    /// rewrites the item. A direct `SecItemCopyMatching` from this app is never on that ACL and
    /// needs the user's approval again after every rewrite. Reading through `security` needs the
    /// app to be outside the App Sandbox, which cannot launch it. CodexBar, TokenEater and CodeBurn
    /// read the item the same way.
    ///
    /// Both paths block (on the child process, or on the SecurityAgent prompt), so this always runs
    /// off the caller's actor via `Task.detached`.
    internal func readCredentials(allowingUserInteraction: Bool) async throws -> ClaudeCodeCredentials {
        try await Task.detached(priority: .userInitiated) {
            let timeout: Duration = allowingUserInteraction
                ? Self.interactiveSecurityToolTimeout
                : Self.silentSecurityToolTimeout
            switch Self.readWithSecurityTool(timeout: timeout) {
            case .payload(let data):
                return try Self.decode(data)
            case .itemNotFound:
                throw ClaudeCodeCredentialsError.itemNotFound
            case .unavailable:
                return try Self.readWithKeychainServices(allowingUserInteraction: allowingUserInteraction)
            }
        }.value
    }

    // MARK: - Private Methods

    private enum SecurityToolResult {
        case payload(Data)
        case itemNotFound
        /// Launch failure, timeout, denial or any other exit code: the caller falls back to
        /// `SecItemCopyMatching`, which maps each of those to a precise error.
        case unavailable
    }

    private static func readWithSecurityTool(timeout: Duration) -> SecurityToolResult {
        let process: Process = Process()
        process.executableURL = securityToolURL
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let standardOutput: Pipe = Pipe()
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .unavailable
        }

        let timeoutTask: Task<Void, Never> = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return }
            process.terminate()
        }
        // Reading to EOF before waiting keeps a large payload from filling the pipe and deadlocking.
        let data: Data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()

        guard process.terminationReason == .exit else { return .unavailable }
        switch process.terminationStatus {
        case 0:
            guard let payload = trimmedPayload(data) else { return .unavailable }
            return .payload(payload)
        case securityToolItemNotFoundExitCode:
            return .itemNotFound
        default:
            return .unavailable
        }
    }

    /// `security -w` prints the password followed by a newline.
    private static func trimmedPayload(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Data(trimmed.utf8)
    }

    private static func readWithKeychainServices(allowingUserInteraction: Bool) throws -> ClaudeCodeCredentials {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowingUserInteraction {
            // The CLI rewrites its item several times a day, and every rewrite drops the grant the
            // user gave this app, so an automatic read regularly needs approval again. Failing
            // instead of prompting turns that into an "Autorizar" button the user presses when they
            // choose, rather than a password dialog popping up out of nowhere.
            //
            // `kSecUseAuthenticationUI` is deprecated in favour of an `LAContext`, but that only
            // governs data-protection items. This one lives in the file-based login keychain, whose
            // ACL prompt only this key controls.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

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
