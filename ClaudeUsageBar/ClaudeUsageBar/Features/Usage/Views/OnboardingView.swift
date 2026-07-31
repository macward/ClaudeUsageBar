import SwiftUI

/// Component: the first-run gate. It exists so the user reads *why* the app needs the Claude Code
/// credential before macOS throws the authorization dialog at them — pressing "Autorizar" is what
/// triggers the very first Keychain read, and nothing touches the Keychain or the network until
/// then. Lives inside the popover: with `LSUIElement` there is no Dock icon and no natural window
/// to host a separate onboarding screen.
internal struct OnboardingView: View {

    // MARK: - Properties

    internal let palette: UsagePalette

    @Environment(UsageMenuViewModel.self) private var viewModel: UsageMenuViewModel

    // MARK: - Body

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ClaudeUsageBar", systemImage: "gauge.with.needle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.title)

            Text("""
                Para mostrarte cuánto llevás consumido, la app necesita leer la sesión de Claude \
                Code que ya tenés guardada en este Mac.
                """)
                .foregroundStyle(palette.title)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Self.bullet("Solo la lee: nunca la modifica ni cierra tu sesión.", systemImage: "eye")
                Self.bullet("Se queda en tu Mac: no se envía a nadie más que a Claude.", systemImage: "lock")
                Self.bullet("Al autorizar, macOS te va a pedir confirmación.", systemImage: "hand.raised")
            }
            .font(UsageMetrics.captionFont)
            .foregroundStyle(palette.secondaryText)

            Button("Autorizar") {
                viewModel.completeOnboarding()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.authorize")
        }
        .accessibilityIdentifier("onboarding")
    }

    // MARK: - Private Methods

    private static func bullet(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Composite: shown when the Keychain refused access. Pure — it takes the retry action as a
/// callback so it stays free of any decision about *when* retrying is allowed; the app must never
/// retry on its own, since every attempt re-opens the system dialog.
internal struct AuthorizationDeniedView: View {

    // MARK: - Properties

    internal let palette: UsagePalette
    internal let onRetry: () -> Void

    // MARK: - Body

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sin acceso a la sesión de Claude Code", systemImage: "lock.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.percentColor(for: .critical))

            Text("""
                No se pudo leer tu sesión porque el acceso fue denegado. Podés volver a \
                intentarlo cuando quieras: macOS te va a preguntar de nuevo.
                """)
                .foregroundStyle(palette.title)
                .fixedSize(horizontal: false, vertical: true)

            Text("Si no aparece el diálogo, revisá el acceso de ClaudeUsageBar en Acceso a Llaveros.")
                .font(UsageMetrics.captionFont)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Reintentar") {
                onRetry()
            }
            .accessibilityIdentifier("onboarding.retry")
        }
        .accessibilityIdentifier("onboarding.denied")
    }
}
