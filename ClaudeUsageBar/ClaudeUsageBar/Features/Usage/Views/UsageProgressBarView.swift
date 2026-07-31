import SwiftUI

/// Pure control: the amber→terracotta usage bar from design 5c. Indivisible, no dependencies, no
/// ViewModel — a percentage and a severity in, a bar out.
internal struct UsageProgressBarView: View {

    // MARK: - Properties

    /// Already-clamped by ``fraction``; callers may pass any integer the endpoint reported,
    /// including the values above 100 it occasionally returns for an exhausted window.
    internal let percentUsed: Int
    internal let severity: UsageDisplayState.Severity
    internal let palette: UsagePalette

    // MARK: - Body

    internal var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.track)

                Capsule(style: .continuous)
                    .fill(palette.fillGradient(for: severity))
                    .frame(width: fillWidth(in: proxy.size.width))
            }
        }
        .frame(height: UsageMetrics.barHeight)
        .accessibilityHidden(true)
    }

    // MARK: - Private Methods

    private var fraction: Double {
        min(max(Double(percentUsed) / 100, 0), 1)
    }

    /// A non-zero percentage never collapses below one bar-height, so a 1% window still reads as a
    /// visible pill rather than a hairline the user would mistake for an empty bar.
    private func fillWidth(in totalWidth: CGFloat) -> CGFloat {
        guard fraction > 0 else { return 0 }
        return max(UsageMetrics.barHeight, totalWidth * fraction)
    }
}
