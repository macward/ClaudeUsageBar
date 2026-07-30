import SwiftUI

/// Pure control: the menu bar icon + text. Configured entirely by the `state` parameter, no
/// ViewModel dependency — every case of `UsageMenuState` maps to a non-empty icon + text pair,
/// so the label is never blank regardless of what the app is doing.
internal struct UsageMenuLabelView: View {

    internal let state: UsageMenuState

    /// An explicit `HStack` rather than `Label`: inside an `NSStatusItem` a `Label` falls back to
    /// its icon-only style, which would hide the percentage — the one number this app exists to
    /// show at a glance.
    internal var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Self.systemImage(for: state))
            Text(Self.text(for: state))
        }
        .accessibilityIdentifier("usage.label")
    }

    private static func text(for state: UsageMenuState) -> String {
        switch state {
        case .onboarding, .loading, .throttled:
            return "—"
        case .fresh(let detail):
            return "\(detail.dominant.percentUsed)%"
        case .stale(let detail, _):
            return "\(detail.dominant.percentUsed)%"
        case .sessionExpired:
            return "!"
        case .error:
            return "!"
        }
    }

    private static func systemImage(for state: UsageMenuState) -> String {
        switch state {
        case .onboarding, .loading:
            return "gauge.with.needle"
        case .fresh(let detail):
            return systemImage(for: detail.dominant.severity)
        case .stale(let detail, _):
            return systemImage(for: detail.dominant.severity)
        case .throttled:
            return "clock"
        case .sessionExpired:
            return "person.crop.circle.badge.exclamationmark"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private static func systemImage(for severity: UsageDisplayState.Severity) -> String {
        switch severity {
        case .normal: return "gauge.with.needle"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.triangle.fill"
        case .unknown: return "gauge.with.needle"
        }
    }
}
