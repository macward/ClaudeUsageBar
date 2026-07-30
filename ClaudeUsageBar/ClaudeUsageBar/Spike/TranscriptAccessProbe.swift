import Foundation

// MARK: - Probe

/// P3: can a sandboxed app read `~/.claude/projects/**.jsonl` without a user-selected bookmark?
///
/// Expected to FAIL: App Sandbox redirects `NSHomeDirectory()` into the container and there is no
/// entitlement that grants arbitrary access to the real home. The probe reports which of the two
/// it hit, because the distinction decides the mitigation (bookmark vs. sandbox off).
internal struct TranscriptAccessProbe {

    internal struct Outcome: Sendable {
        internal let homeDirectory: String
        internal let isContainerRedirected: Bool
        internal let resolvedPath: String
        internal let claudeDirectoryExists: Bool
        internal let readableTranscripts: Int
        internal let firstReadError: String?
    }

    internal func inspect() -> Outcome {
        let sandboxHome: String = NSHomeDirectory()
        let isRedirected: Bool = sandboxHome.contains("/Library/Containers/")

        // The real home, bypassing the container redirection.
        let realHome: String = "/Users/\(NSUserName())"
        let projects: URL = URL(fileURLWithPath: realHome)
            .appendingPathComponent(".claude/projects", isDirectory: true)

        let manager: FileManager = FileManager.default
        let exists: Bool = manager.fileExists(atPath: projects.path)

        var readable: Int = 0
        var firstError: String?

        if let walker = manager.enumerator(atPath: projects.path) {
            for case let relative as String in walker where relative.hasSuffix(".jsonl") {
                let file: URL = projects.appendingPathComponent(relative)
                do {
                    let handle: FileHandle = try FileHandle(forReadingFrom: file)
                    try handle.close()
                    readable += 1
                    if readable >= 3 { break }
                } catch {
                    if firstError == nil { firstError = String(describing: error) }
                    break
                }
            }
        } else if exists {
            firstError = "enumerator(atPath:) devolvió nil — directorio bloqueado por el sandbox"
        } else {
            firstError = "no existe o es invisible desde el sandbox"
        }

        return Outcome(
            homeDirectory: sandboxHome,
            isContainerRedirected: isRedirected,
            resolvedPath: projects.path,
            claudeDirectoryExists: exists,
            readableTranscripts: readable,
            firstReadError: firstError
        )
    }
}
