import Foundation

/// Presentation-ready projection of usage data. No optionals — a caller (currently
/// `UsageMenuViewModel.deriveDisplayState`) is responsible for deciding whether a snapshot
/// carries enough data to build one at all.
internal nonisolated struct UsageDisplayState: Equatable, Sendable {

    internal enum Severity: String, Sendable {
        case normal
        case warning
        case critical
        case unknown
    }

    internal let percentUsed: Int
    internal let severity: Severity
    internal let windowKind: String
    internal let resetsAt: Date

    internal init(percentUsed: Int, severity: Severity, windowKind: String, resetsAt: Date) {
        self.percentUsed = percentUsed
        self.severity = severity
        self.windowKind = windowKind
        self.resetsAt = resetsAt
    }
}
