import Foundation

/// DTO for `GET /api/oauth/usage`. Every field is optional on purpose: this is an
/// undocumented endpoint that ships internal feature-flag keys (`tangelo`,
/// `seven_day_omelette`, `iguana_necktie`…) which will come and go. Missing or
/// unknown keys must never fail the whole decode.
internal nonisolated struct UsageSnapshot: Codable, Sendable, Equatable {

    internal nonisolated struct Window: Codable, Sendable, Equatable {
        internal let utilization: Double?
        internal let resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    internal nonisolated struct Limit: Codable, Sendable, Equatable {
        internal let kind: String?
        internal let group: String?
        internal let percent: Double?
        internal let severity: String?
        internal let resetsAt: Date?
        internal let isActive: Bool?

        private enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }
    }

    internal let fiveHour: Window?
    internal let sevenDay: Window?
    internal let limits: [Limit]?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }
}

nonisolated extension JSONDecoder {

    /// A decoder preconfigured for `UsageSnapshot`'s fractional-second timestamps.
    internal static var usageSnapshot: JSONDecoder {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .fractionalISO8601
        return decoder
    }
}
