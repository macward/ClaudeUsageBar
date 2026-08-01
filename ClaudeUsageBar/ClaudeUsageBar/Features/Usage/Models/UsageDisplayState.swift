import Foundation

/// Presentation-ready projection of usage data. A caller (currently
/// `UsageMenuViewModel.deriveDisplayState`) is responsible for deciding whether a snapshot
/// carries enough data to build one at all — which comes down to a percentage, and nothing else.
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
    /// When the window rolls over, or `nil` when the server didn't say.
    ///
    /// Optional because a window with no usage in it has nothing to reset: the endpoint answers
    /// `{"utilization": 0}` with no `resets_at` at all. Requiring the date is what used to make the
    /// whole "Últimas 5 horas" row vanish the moment the session window emptied out — and, with the
    /// session gone, sent the menu bar percentage falling back to the weekly number. A row missing
    /// its reset time is still worth showing; a percentage is the part nobody can infer.
    internal let resetsAt: Date?

    internal init(percentUsed: Int, severity: Severity, windowKind: String, title: String, resetsAt: Date?) {
        self.percentUsed = percentUsed
        self.severity = severity
        self.windowKind = windowKind
        self.title = title
        self.resetsAt = resetsAt
    }
}
