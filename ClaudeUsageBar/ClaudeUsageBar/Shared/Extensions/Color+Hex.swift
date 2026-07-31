import SwiftUI

extension Color {

    /// Builds a color from a 24-bit RGB hex literal, e.g. `0xD9_77_57`.
    ///
    /// The palette in ``UsagePalette`` is transcribed from a web design doc where every value is a
    /// hex string, so keeping the source form makes the two readable side by side. Takes an `Int`
    /// rather than a `String` precisely because there is no parse to fail: a malformed literal is a
    /// compile error instead of a silently transparent color.
    /// `nonisolated` is load-bearing: the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor`, so without it this initializer is main-actor-isolated and cannot appear in the
    /// nonisolated `static let` palettes that use it.
    internal nonisolated init(hex: Int, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
