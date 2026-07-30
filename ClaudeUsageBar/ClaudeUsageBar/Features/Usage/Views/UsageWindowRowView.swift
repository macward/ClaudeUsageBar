import SwiftUI

/// Pure composite: one usage window's title, percent, and a relative + absolute reset time.
/// No dependencies, no ViewModel — configured entirely through its parameters, reusable for
/// the 5h window, the weekly window, and any per-limit entry. The title travels inside
/// ``UsageDisplayState`` because deciding it (mapping an endpoint key to a label) is logic that
/// belongs to the ViewModel, not here.
internal struct UsageWindowRowView: View {

    internal let display: UsageDisplayState

    internal var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(display.title)
                    .font(.headline)
                Spacer()
                Text("\(display.percentUsed)%")
                    .font(.headline)
                    .foregroundStyle(Self.color(for: display.severity))
            }

            // The countdown ticks once a minute via TimelineView, never on every second —
            // this view holds no Timer of its own. The tick's own date drives the formatter, so
            // the text is a pure function of the timeline context rather than of a `Date()` read
            // hidden inside the body.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack {
                    Text("Reinicia en \(RemainingTimeFormatter.duration(until: display.resetsAt, now: context.date))")
                    Spacer()
                    Text(display.resetsAt, format: .dateTime.hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
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
