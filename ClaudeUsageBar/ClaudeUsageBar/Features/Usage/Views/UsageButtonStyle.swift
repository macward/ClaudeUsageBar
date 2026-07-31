import SwiftUI

/// The popover's button treatment from design 5c: a soft filled pill that lifts on hover.
///
/// A `ButtonStyle` cannot read `@Environment` directly, so the actual chrome lives in a private
/// nested view — that is what lets a disabled button dim itself rather than looking pressable.
internal struct UsageButtonStyle: ButtonStyle {

    // MARK: - Properties

    internal let palette: UsagePalette

    // MARK: - Public Methods

    internal func makeBody(configuration: Configuration) -> some View {
        ButtonChrome(configuration: configuration, palette: palette)
    }

    // MARK: - Chrome

    private struct ButtonChrome: View {

        internal let configuration: Configuration
        internal let palette: UsagePalette

        @Environment(\.isEnabled) private var isEnabled: Bool
        @State private var isHovered: Bool = false

        internal var body: some View {
            configuration.label
                .font(UsageMetrics.buttonFont)
                .foregroundStyle(palette.buttonText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(shape.fill(background))
                .overlay(shape.strokeBorder(palette.buttonBorder, lineWidth: 1))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
        }

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: UsageMetrics.buttonCornerRadius, style: .continuous)
        }

        private var background: Color {
            guard isEnabled else { return palette.buttonBackground }
            if configuration.isPressed { return palette.buttonBackgroundPressed }
            return isHovered ? palette.buttonBackgroundHovered : palette.buttonBackground
        }
    }
}
