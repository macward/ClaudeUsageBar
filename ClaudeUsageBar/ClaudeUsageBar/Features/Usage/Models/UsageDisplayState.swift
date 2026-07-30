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
    /// The raw key this row came from (`five_hour`, `weekly_all`, a per-model limit's `kind`…).
    /// Kept for identity and diagnostics — never rendered. The endpoint is undocumented and its
    /// keys come and go, so what reaches the screen is ``title``.
    internal let windowKind: String
    /// The user-facing row title, already resolved by the ViewModel. Never empty, even when
    /// `windowKind` is a key this build has never seen.
    internal let title: String
    internal let resetsAt: Date

    internal init(percentUsed: Int, severity: Severity, windowKind: String, title: String, resetsAt: Date) {
        self.percentUsed = percentUsed
        self.severity = severity
        self.windowKind = windowKind
        self.title = title
        self.resetsAt = resetsAt
    }
}
