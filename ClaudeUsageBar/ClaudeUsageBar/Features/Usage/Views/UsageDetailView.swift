import AppKit
import SwiftUI

/// Component: connects to ``UsageMenuViewModel`` and renders the full popover — both usage
/// windows, any active per-limit entries, freshness, and the refresh/quit actions. Paints only
/// what the ViewModel's already-resolved `state` says; no thresholds or policy decisions live
/// here.
internal struct UsageDetailView: View {

    @Environment(UsageMenuViewModel.self) private var viewModel: UsageMenuViewModel

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            Divider()
            actions
        }
        .padding()
        .frame(width: 300)
        .accessibilityIdentifier("usage.detail")
        .task { await viewModel.refreshOnPopoverOpen() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .onboarding:
            OnboardingView()
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        case .fresh(let detail):
            windows(detail)
        case .stale(let detail, let age):
            VStack(alignment: .leading, spacing: 8) {
                Label(Self.stalenessText(age: age), systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                windows(detail)
            }
        case .throttled(let until):
            Text(Self.throttledText(until: until))
                .foregroundStyle(.secondary)
        case .sessionExpired:
            Label(
                "Tu sesión expiró. Iniciá sesión de nuevo con `claude` en la terminal.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        case .error(let error):
            // An authorization failure is the one error with its own recovery path, so it gets a
            // dedicated view with an explicit retry instead of the generic error line.
            if viewModel.isAwaitingAuthorizationRetry {
                AuthorizationDeniedView { Task { await viewModel.retryAuthorization() } }
            } else {
                Label(Self.errorText(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func windows(_ detail: UsageDetailData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let fiveHour: UsageDisplayState = detail.fiveHour {
                UsageWindowRowView(title: "Últimas 5 horas", display: fiveHour)
            }
            if let sevenDay: UsageDisplayState = detail.sevenDay {
                UsageWindowRowView(title: "Semanal", display: sevenDay)
            }
            if !detail.limits.isEmpty {
                Divider()
                ForEach(Array(detail.limits.enumerated()), id: \.offset) { _, limit in
                    UsageWindowRowView(title: limit.windowKind, display: limit)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Actualizar") {
                Task { await viewModel.refresh() }
            }
            // Disabled before onboarding (it would be a no-op) and while access is denied, where
            // "Reintentar" is the one path that both re-prompts and restarts the polling loop.
            .disabled(isThrottled || isOnboarding || viewModel.isAwaitingAuthorizationRetry)
            .accessibilityIdentifier("usage.refresh")

            if case .throttled(let until) = viewModel.state {
                Text(Self.throttledText(until: until))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Salir") {
                NSApplication.shared.terminate(nil)
            }
            .accessibilityIdentifier("usage.quit")
        }
    }

    private var isThrottled: Bool {
        if case .throttled = viewModel.state { return true }
        return false
    }

    private var isOnboarding: Bool {
        if case .onboarding = viewModel.state { return true }
        return false
    }

    // MARK: - Private Methods

    private static func stalenessText(age: TimeInterval) -> String {
        let formatter: RelativeDateTimeFormatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let ago: String = formatter.localizedString(fromTimeInterval: -age)
        return "Datos de \(ago)"
    }

    private static func throttledText(until: Date) -> String {
        let formatter: RelativeDateTimeFormatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Podés reintentar \(formatter.localizedString(for: until, relativeTo: Date()))"
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
