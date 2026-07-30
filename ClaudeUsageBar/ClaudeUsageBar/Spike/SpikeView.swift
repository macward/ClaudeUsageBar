import SwiftUI

// MARK: - View

internal struct SpikeView: View {

    @Environment(SpikeViewModel.self) private var viewModel

    internal var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ForEach(viewModel.probes) { probe in
                ProbeRow(probe: probe)
            }

            if !viewModel.rawResponse.isEmpty {
                Divider()
                DisclosureGroup("Respuesta cruda del endpoint") {
                    ScrollView {
                        Text(viewModel.rawResponse)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                }
                .font(.caption)
            }

            Divider()
            HStack {
                Button("Re-ejecutar") {
                    Task { await viewModel.runAll() }
                }
                .disabled(viewModel.isRunning)
                .accessibilityIdentifier("spike.rerun")

                Spacer()

                Button("Salir") { NSApplication.shared.terminate(nil) }
                    .accessibilityIdentifier("spike.quit")
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: - Private Views

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Spike de viabilidad")
                .font(.headline)
            Text("App sandboxed · hardened runtime")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Composite

private struct ProbeRow: View {

    fileprivate let probe: SpikeProbe

    fileprivate var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: probe.status.symbol)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(probe.title)
                    .font(.subheadline.weight(.semibold))
                Text(probe.question)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !probe.detail.isEmpty {
                    Text(probe.detail)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                }
            }
        }
        .accessibilityIdentifier("spike.probe.\(probe.id)")
    }

    private var tint: Color {
        switch probe.status {
        case .pending: return .secondary
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        }
    }
}
