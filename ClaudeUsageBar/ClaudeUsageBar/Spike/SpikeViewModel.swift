import Foundation
import OSLog

// MARK: - View Model

@Observable
@MainActor
internal final class SpikeViewModel {

    // MARK: - Properties

    internal private(set) var probes: [SpikeProbe] = [
        SpikeProbe(
            id: "keychain",
            title: "P1 · Keychain cross-app",
            question: "¿Puede una app sandboxed leer el item que escribió el CLI `claude`?"
        ),
        SpikeProbe(
            id: "network",
            title: "P2 · Endpoint /api/oauth/usage",
            question: "¿Llega la app al endpoint y decodifica la respuesta?"
        ),
        SpikeProbe(
            id: "transcripts",
            title: "P3 · Lectura de ~/.claude/projects",
            question: "¿Se pueden leer los .jsonl sin bookmark del usuario?"
        )
    ]

    internal private(set) var isRunning: Bool = false
    internal private(set) var rawResponse: String = ""

    private let keychainProbe: KeychainCredentialsProbe
    private let usageProbe: UsageAPIProbe
    private let transcriptProbe: TranscriptAccessProbe
    private let logger: Logger = Logger(subsystem: "com.maxward.ClaudeUsageBar", category: "Spike")

    // MARK: - Lifecycle

    internal init(
        keychainProbe: KeychainCredentialsProbe = KeychainCredentialsProbe(),
        usageProbe: UsageAPIProbe = UsageAPIProbe(),
        transcriptProbe: TranscriptAccessProbe = TranscriptAccessProbe()
    ) {
        self.keychainProbe = keychainProbe
        self.usageProbe = usageProbe
        self.transcriptProbe = transcriptProbe
    }

    // MARK: - Public Methods

    internal func runAll() async {
        guard !isRunning else { return }
        isRunning = true
        rawResponse = ""
        for index in probes.indices {
            probes[index].status = .pending
            probes[index].detail = ""
        }

        let credentials: ClaudeCodeCredentials? = runKeychainProbe()
        await runUsageProbe(credentials: credentials)
        runTranscriptProbe()

        isRunning = false
        emitSummary()
    }

    /// Writes a plain-text report to stderr so the spike can be evaluated without opening the
    /// popover. Spike-only affordance — the real app has no reason to print.
    private func emitSummary() {
        var lines: [String] = ["", "===== SPIKE RESULTS ====="]
        for probe in probes {
            let verdict: String = switch probe.status {
            case .passed: "PASS"
            case .failed: "FAIL"
            default: "????"
            }
            lines.append("[\(verdict)] \(probe.title)")
            for line in probe.detail.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("        \(line)")
            }
        }
        lines.append("===== END SPIKE =====")
        let report: String = lines.joined(separator: "\n")

        FileHandle.standardError.write(Data(report.utf8))
        // stdio disappears when launched via launchd, and the sandbox forbids writing outside the
        // container — so OSLog plus a container file are the only durable channels.
        logger.notice("\(report, privacy: .public)")

        let destination: URL = URL.documentsDirectory.appendingPathComponent("spike-report.txt")
        try? report.write(to: destination, atomically: true, encoding: .utf8)
    }

    // MARK: - Private Methods

    private func runKeychainProbe() -> ClaudeCodeCredentials? {
        update("keychain") { $0.status = .running }
        do {
            let credentials: ClaudeCodeCredentials = try keychainProbe.read()
            let expiry: String = credentials.expiresAt.formatted(date: .omitted, time: .standard)
            let freshness: String = credentials.isExpired ? "CADUCADO" : "válido hasta \(expiry)"
            update("keychain") {
                $0.status = .passed
                $0.detail = """
                    token \(credentials.redactedToken)
                    plan: \(credentials.subscriptionType) · \(freshness)
                    scopes: \(credentials.scopes.joined(separator: ", "))
                    """
            }
            return credentials
        } catch {
            logger.error("P1 falló: \(String(describing: error), privacy: .public)")
            update("keychain") {
                $0.status = .failed
                $0.detail = String(describing: error)
            }
            return nil
        }
    }

    private func runUsageProbe(credentials: ClaudeCodeCredentials?) async {
        guard let credentials else {
            update("network") {
                $0.status = .failed
                $0.detail = "bloqueado: sin token porque P1 falló"
            }
            return
        }

        update("network") { $0.status = .running }
        do {
            let result: (snapshot: UsageSnapshot, rawBody: String) = try await usageProbe.fetch(
                accessToken: credentials.accessToken
            )
            rawResponse = result.rawBody

            let fiveHour: String = Self.describe(result.snapshot.fiveHour)
            let sevenDay: String = Self.describe(result.snapshot.sevenDay)
            let limitCount: Int = result.snapshot.limits?.count ?? 0
            update("network") {
                $0.status = .passed
                $0.detail = """
                    5h:  \(fiveHour)
                    7d:  \(sevenDay)
                    limits[]: \(limitCount) entradas
                    """
            }
        } catch {
            logger.error("P2 falló: \(String(describing: error), privacy: .public)")
            update("network") {
                $0.status = .failed
                $0.detail = String(describing: error)
            }
        }
    }

    private func runTranscriptProbe() {
        update("transcripts") { $0.status = .running }
        let outcome: TranscriptAccessProbe.Outcome = transcriptProbe.inspect()
        let passed: Bool = outcome.readableTranscripts > 0
        update("transcripts") {
            $0.status = passed ? .passed : .failed
            $0.detail = """
                NSHomeDirectory(): \(outcome.isContainerRedirected ? "redirigido al container" : "home real")
                \(outcome.homeDirectory)
                existe \(outcome.resolvedPath): \(outcome.claudeDirectoryExists ? "sí" : "no")
                .jsonl abiertos: \(outcome.readableTranscripts)
                \(outcome.firstReadError.map { "error: \($0)" } ?? "")
                """
        }
    }

    private func update(_ id: String, _ mutate: (inout SpikeProbe) -> Void) {
        guard let index = probes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&probes[index])
    }

    private static func describe(_ window: UsageSnapshot.Window?) -> String {
        guard let window else { return "ausente en la respuesta" }
        let percent: String = window.utilization.map { "\(Int($0))%" } ?? "—"
        let reset: String = window.resetsAt.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "sin reset"
        return "\(percent) usado · reset \(reset)"
    }
}
