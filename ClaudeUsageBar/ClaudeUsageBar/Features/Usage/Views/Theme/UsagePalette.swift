import SwiftUI

/// The popover's color palette, transcribed from the "Naranja Claude" design doc: variant **5c**
/// (warm dark, amber→terracotta gradient) for dark appearance and variant **5b** (cream) for light.
///
/// It is a value, not a set of globals, so every view receives its palette explicitly and stays
/// renderable in isolation. ``UsagePalette/resolved(for:)`` is the only place that maps a
/// `ColorScheme` to a variant — views never branch on appearance themselves.
internal nonisolated struct UsagePalette: Equatable, Sendable {

    // MARK: - Properties

    /// Popover background, painted edge to edge. The rounded corners and shadow in the design come
    /// from the system window under `MenuBarExtra(.window)`, so this carries no border or radius.
    internal let surface: Color
    internal let separator: Color
    internal let title: Color
    internal let secondaryText: Color
    /// Unfilled part of a usage bar.
    internal let track: Color
    internal let buttonBackground: Color
    internal let buttonBackgroundHovered: Color
    internal let buttonBackgroundPressed: Color
    internal let buttonBorder: Color
    internal let buttonText: Color
    /// Severity-keyed colors for the percentage label and the bar fill. The design hardcodes a
    /// single amber→terracotta gradient; the app escalates it because severity is real state the
    /// menu bar icon already reflects, and a bar that never changes color would contradict it.
    private let percentColors: [UsageDisplayState.Severity: Color]
    private let fillGradients: [UsageDisplayState.Severity: [Color]]

    // MARK: - Public Methods

    internal static func resolved(for colorScheme: ColorScheme) -> UsagePalette {
        colorScheme == .dark ? .dark : .light
    }

    internal func percentColor(for severity: UsageDisplayState.Severity) -> Color {
        percentColors[severity] ?? secondaryText
    }

    internal func fillGradient(for severity: UsageDisplayState.Severity) -> LinearGradient {
        LinearGradient(
            colors: fillGradients[severity] ?? [secondaryText, secondaryText],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Variants

    /// Design doc 5c — "Degradado cálido ámbar→terracota".
    internal static let dark: UsagePalette = UsagePalette(
        surface: Color(hex: 0x1E1A17, opacity: 0.97),
        separator: Color.white.opacity(0.05),
        title: Color(hex: 0xF2EDE6),
        secondaryText: Color(hex: 0x9A9188),
        track: Color(hex: 0xEBA779, opacity: 0.13),
        buttonBackground: Color.white.opacity(0.07),
        buttonBackgroundHovered: Color.white.opacity(0.13),
        buttonBackgroundPressed: Color.white.opacity(0.18),
        buttonBorder: Color.clear,
        buttonText: Color(hex: 0xF2EDE6),
        percentColors: darkPercentColors,
        fillGradients: darkFillGradients
    )

    private static let darkPercentColors: [UsageDisplayState.Severity: Color] = [
        .normal: Color(hex: 0xEBA779),
        .warning: Color(hex: 0xF0B65C),
        .critical: Color(hex: 0xF07A66),
        .unknown: Color(hex: 0x9A9188)
    ]

    private static let darkFillGradients: [UsageDisplayState.Severity: [Color]] = [
        .normal: [Color(hex: 0xE8A05C), Color(hex: 0xD97757)],
        .warning: [Color(hex: 0xF0B65C), Color(hex: 0xE07A3C)],
        .critical: [Color(hex: 0xE86B52), Color(hex: 0xB8342A)],
        .unknown: [Color(hex: 0x6E6862), Color(hex: 0x56514C)]
    ]

    /// Design doc 5b — "Crema claro estilo Claude", carrying 5c's gradient so both appearances
    /// escalate identically.
    internal static let light: UsagePalette = UsagePalette(
        surface: Color(hex: 0xF5F3EC),
        separator: Color(hex: 0xE8E4D9),
        title: Color(hex: 0x29261F),
        secondaryText: Color(hex: 0x8A8375),
        track: Color(hex: 0xE6DFD2),
        buttonBackground: Color.white,
        buttonBackgroundHovered: Color(hex: 0xEFEBE0),
        buttonBackgroundPressed: Color(hex: 0xE6E1D3),
        buttonBorder: Color(hex: 0xDBD5C6),
        buttonText: Color(hex: 0x29261F),
        percentColors: lightPercentColors,
        fillGradients: lightFillGradients
    )

    private static let lightPercentColors: [UsageDisplayState.Severity: Color] = [
        .normal: Color(hex: 0xC25E3C),
        .warning: Color(hex: 0xB4560F),
        .critical: Color(hex: 0xA32A1E),
        .unknown: Color(hex: 0x8A8375)
    ]

    private static let lightFillGradients: [UsageDisplayState.Severity: [Color]] = [
        .normal: [Color(hex: 0xE8A05C), Color(hex: 0xD97757)],
        .warning: [Color(hex: 0xF0B65C), Color(hex: 0xE07A3C)],
        .critical: [Color(hex: 0xE86B52), Color(hex: 0xB8342A)],
        .unknown: [Color(hex: 0xBDB6A6), Color(hex: 0xA29B8C)]
    ]
}

/// Fixed dimensions from the design doc. Grouped as a namespace rather than scattered as literals
/// so the popover's rhythm (row padding, bar height, gaps) stays adjustable in one place.
internal nonisolated enum UsageMetrics {

    /// Popover width — 312pt in the design.
    internal static let popoverWidth: CGFloat = 312
    internal static let rowHorizontalPadding: CGFloat = 16
    internal static let rowTopPadding: CGFloat = 13
    internal static let rowBottomPadding: CGFloat = 14
    internal static let rowSpacing: CGFloat = 7
    internal static let barHeight: CGFloat = 5
    internal static let actionsHorizontalPadding: CGFloat = 12
    internal static let actionsVerticalPadding: CGFloat = 10
    internal static let buttonCornerRadius: CGFloat = 7

    internal static let titleFont: Font = .system(size: 13, weight: .medium)
    internal static let percentFont: Font = .system(size: 13, weight: .bold)
    internal static let captionFont: Font = .system(size: 11)
    internal static let buttonFont: Font = .system(size: 12.5, weight: .medium)
}
