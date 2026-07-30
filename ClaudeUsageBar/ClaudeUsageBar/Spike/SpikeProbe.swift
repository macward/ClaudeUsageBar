import Foundation

// MARK: - Probe Result

/// Outcome of a single spike probe. Throwaway type — the real app models this differently.
internal struct SpikeProbe: Identifiable, Sendable {
    internal let id: String
    internal let title: String
    internal let question: String
    internal var status: Status = .pending
    internal var detail: String = ""

    internal enum Status: Sendable {
        case pending
        case running
        case passed
        case failed

        internal var symbol: String {
            switch self {
            case .pending: return "circle.dotted"
            case .running: return "circle.dashed"
            case .passed: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }
    }
}
