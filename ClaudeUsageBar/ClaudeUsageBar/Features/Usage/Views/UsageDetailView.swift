import AppKit
import SwiftUI

/// Component: connects to ``UsageMenuViewModel`` and renders the full popover — both usage
/// windows, any active per-limit entries, freshness, and the refresh/quit actions. Paints only
/// what the ViewModel's already-resolved `state` says; no thresholds or policy decisions live
/// here.
///
/// Visually this is design 5c ("Naranja Claude", warm dark) with 5b's cream palette standing in
/// under a light appearance; ``UsagePalette`` holds both. The card's radius, border and shadow are
/// left to the system: `MenuBarExtra(.window)` already draws them, and painting a second set
/// inside would double up.
internal struct UsageDetailView: View {

    // MARK: - Properties

    @Environment(UsageMenuViewModel.self) private var viewModel: UsageMenuViewModel
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    private var palette: UsagePalette {
        UsagePalette.resolved(for: colorScheme)
    }

    // MARK: - Body

    /// The half-minute tick keeps the "actualizado hace…" footer and any countdown honest while
    /// the popover stays open, instead of freezing at whatever they read when it was first drawn.
    internal var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                content(at: context.date)
                separator
                footer(at: context.date)
            }
        }
        .frame(width: UsageMetrics.popoverWidth)
        .background(palette.surface)
        .buttonStyle(UsageButtonStyle(palette: palette))
        .accessibilityIdentifier("usage.detail")
        .task { await viewModel.refreshOnPopoverOpen() }
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        switch viewModel.state {
        case .onboarding:
            message { OnboardingView(palette: palette) }
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        case .fresh(let detail):
            windows(detail)
        case .stale(let detail, let age):
            VStack(alignment: .leading, spacing: 0) {
                notice(Self.stalenessText(age: age), systemImage: "clock.arrow.circlepath")
                windows(detail)
            }
        case .throttled(let until):
            // Reachable only before any snapshot has ever landed. The wording says what the app
            // will do rather than what the user should do: with no manual refresh left, the
            // polling loop is the only thing that retries.
            message {
                Label(Self.retryingText(until: until, now: now), systemImage: "clock")
                    .foregroundStyle(palette.secondaryText)
            }
        case .sessionExpired:
            message {
                Label(
                    "Tu sesión expiró. Iniciá sesión de nuevo con `claude` en la terminal.",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .foregroundStyle(palette.title)
            }
        case .error(let error):
            // An authorization failure is the one error with its own recovery path, so it gets a
            // dedicated view with an explicit retry instead of the generic error line.
            message {
                if viewModel.isAwaitingAuthorizationRetry {
                    AuthorizationDeniedView(palette: palette) {
                        Task { await viewModel.retryAuthorization() }
                    }
                } else {
                    Label(Self.errorText(error), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.percentColor(for: .critical))
                }
            }
        }
    }

    /// Every non-window state reuses the row's horizontal rhythm so the popover keeps one margin
    /// regardless of what it is showing.
    private func message<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, UsageMetrics.rowHorizontalPadding)
            .padding(.top, UsageMetrics.rowTopPadding)
            .padding(.bottom, UsageMetrics.rowBottomPadding)
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(UsageMetrics.captionFont)
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, UsageMetrics.rowHorizontalPadding)
            .padding(.top, UsageMetrics.rowTopPadding)
    }

    /// All rows share one separator rhythm — the five-hour window, the weekly window and each
    /// per-limit entry are visually peers, so no group gets a heavier rule than the others.
    @ViewBuilder
    private func windows(_ detail: UsageDetailData) -> some View {
        // Every row title — including the two named windows — is resolved by the ViewModel,
        // so no endpoint key ever reaches the screen unmapped.
        let rows: [UsageDisplayState] = [detail.fiveHour, detail.sevenDay].compactMap(\.self) + detail.limits

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    separator
                }
                UsageWindowRowView(display: row, palette: palette)
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 1)
    }

    /// There is deliberately no "Actualizar" action here.
    ///
    /// It was removed because it could not do its job: the repository allows one fetch per 180s,
    /// and the polling loop already sleeps until exactly that deadline and fetches then. Every
    /// other trigger is covered too — system wake by the `didWakeNotification` observer, and
    /// opening the popover by ``UsageMenuViewModel/refreshOnPopoverOpen()``. A manual button could
    /// therefore only ever repeat work the app was about to do anyway, or refuse. What it was
    /// really being asked ("is this number current?") is answered by the freshness text instead.
    ///
    /// The one genuinely user-driven retry that remains is "Reintentar" inside
    /// ``AuthorizationDeniedView``, where the polling loop is deliberately stopped and only an
    /// explicit action may re-open the Keychain prompt.
    private func footer(at now: Date) -> some View {
        HStack(spacing: 8) {
            if let text: String = freshnessText(at: now) {
                Text(text)
                    .font(UsageMetrics.captionFont)
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityIdentifier("usage.freshness")
            }

            Spacer(minLength: 0)

            Button("Salir") {
                NSApplication.shared.terminate(nil)
            }
            .accessibilityIdentifier("usage.quit")
        }
        .padding(.horizontal, UsageMetrics.actionsHorizontalPadding)
        .padding(.vertical, UsageMetrics.actionsVerticalPadding)
    }

    /// `nil` until the first snapshot lands — before that there is no age to report, and the
    /// popover is already saying what it is doing (onboarding, loading, or an error).
    private func freshnessText(at now: Date) -> String? {
        guard let fetchedAt: Date = viewModel.currentSnapshotFetchedAt else { return nil }
        let formatter: RelativeDateTimeFormatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Actualizado \(formatter.localizedString(for: fetchedAt, relativeTo: now))"
    }

    // MARK: - Private Methods

    private static func stalenessText(age: TimeInterval) -> String {
        let formatter: RelativeDateTimeFormatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let ago: String = formatter.localizedString(fromTimeInterval: -age)
        return "Datos de \(ago)"
    }

    private static func retryingText(until: Date, now: Date) -> String {
        "Reintentando en \(RemainingTimeFormatter.duration(until: until, now: now))"
    }

    private static func errorText(_ error: UsageMenuError) -> String {
        switch error {
        case .repository(let repositoryError):
            return errorText(repositoryError)
        case .noUsableData:
            return "La respuesta del servidor no trae datos de uso utilizables."
        }
    }

    private static func errorText(_ error: UsageRepositoryError) -> String {
        switch error {
        case .credentialsUnavailable(let underlying):
            return credentialsErrorText(underlying)
        case .offline:
            return "Sin conexión. ClaudeUsageBar reintentará automáticamente cuando vuelva la red."
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "Demasiadas solicitudes. Reintentá más tarde." }
            return "Demasiadas solicitudes. Reintentá en \(Int(retryAfter))s."
        case .serverError(let code):
            return "El servidor de Claude respondió con un error (\(code))."
        case .decodingFailed:
            return "No se pudo interpretar la respuesta del servidor."
        case .networkError:
            return "Error de red. Reintentá en un momento."
        }
    }

    private static func credentialsErrorText(_ error: ClaudeCodeCredentialsError) -> String {
        switch error {
        case .itemNotFound:
            return "No hay sesión activa de Claude Code. Iniciá sesión con `claude` en la terminal."
        case .interactionNotAllowed, .missingAuthorization, .userDeniedAccess:
            return "Acceso al llavero denegado. Autorizá a ClaudeUsageBar a leer las credenciales de Claude Code."
        case .unexpectedStatus, .malformedPayload, .missingOAuthSection:
            return "No se pudo leer la sesión de Claude Code (error inesperado)."
        }
    }
}
