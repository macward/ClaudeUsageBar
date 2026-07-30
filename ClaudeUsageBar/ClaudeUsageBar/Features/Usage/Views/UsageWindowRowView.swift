import SwiftUI

/// Pure composite: one usage window's title, percent, and a relative + absolute reset time.
/// No dependencies, no ViewModel — configured entirely through its parameters, reusable for
/// the 5h window, the weekly window, and any per-limit entry.
internal struct UsageWindowRowView: View {

    internal let title: String
    internal let display: UsageDisplayState

    internal var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(display.percentUsed)%")
                    .font(.headline)
                    .foregroundStyle(Self.color(for: display.severity))
            }

            // The countdown ticks once a minute via TimelineView, never on every second —
            // this view holds no Timer of its own.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                HStack {
                    Text(Self.relativeReset(display.resetsAt))
                    Spacer()
                    Text(display.resetsAt, format: .dateTime.hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private static func relativeReset(_ date: Date) -> String {
        let formatter: RelativeDateTimeFormatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func color(for severity: UsageDisplayState.Severity) -> Color {
        switch severity {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}
