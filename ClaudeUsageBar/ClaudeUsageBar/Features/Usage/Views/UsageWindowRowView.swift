import SwiftUI

/// Pure composite: one usage window's title, percent, the amber→terracotta bar from design 5c, and
/// a relative + absolute reset time. No dependencies, no ViewModel — configured entirely through
/// its parameters, reusable for the 5h window, the weekly window, and any per-limit entry. The
/// title travels inside ``UsageDisplayState`` because deciding it (mapping an endpoint key to a
/// label) is logic that belongs to the ViewModel, not here.
///
/// It owns its own horizontal padding so the row's separator, drawn by the container, can run edge
/// to edge the way the design has it.
internal struct UsageWindowRowView: View {

    // MARK: - Properties

    internal let display: UsageDisplayState
    internal let palette: UsagePalette

    // MARK: - Body

    internal var body: some View {
        VStack(alignment: .leading, spacing: UsageMetrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.title)
                    .font(UsageMetrics.titleFont)
                    .foregroundStyle(palette.title)
                Spacer(minLength: 8)
                Text("\(display.percentUsed)%")
                    .font(UsageMetrics.percentFont)
                    .foregroundStyle(palette.percentColor(for: display.severity))
            }

            UsageProgressBarView(
                percentUsed: display.percentUsed,
                severity: display.severity,
                palette: palette
            )

            // With no reset time the countdown has nothing to count, so the row says why instead of
            // rendering an empty or invented one. It keeps the same caption slot, so a row that
            // gains or loses its date doesn't change height.
            if let resetsAt = display.resetsAt {
                // The countdown ticks once a minute via TimelineView, never on every second —
                // this view holds no Timer of its own. The tick's own date drives the formatter, so
                // the text is a pure function of the timeline context rather than of a `Date()` read
                // hidden inside the body.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack {
                        Text("Reinicia en \(RemainingTimeFormatter.duration(until: resetsAt, now: context.date))")
                        Spacer(minLength: 8)
                        Text(resetsAt, format: .dateTime.hour().minute())
                    }
                    .font(UsageMetrics.captionFont)
                    .foregroundStyle(palette.secondaryText)
                }
            } else {
                Text("Sin ventana activa")
                    .font(UsageMetrics.captionFont)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, UsageMetrics.rowHorizontalPadding)
        .padding(.top, UsageMetrics.rowTopPadding)
        .padding(.bottom, UsageMetrics.rowBottomPadding)
    }
}
