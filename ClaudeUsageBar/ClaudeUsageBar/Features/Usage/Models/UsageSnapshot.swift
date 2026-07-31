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

    /// What a `limits[]` entry is narrowed to. Only present on scoped entries
    /// (`kind: "weekly_scoped"`), where it carries the one piece of information that identifies
    /// *which* model the cap applies to — the top-level per-model keys (`seven_day_opus`,
    /// `seven_day_sonnet`, `seven_day_omelette`…) are all null in practice.
    internal nonisolated struct Scope: Codable, Sendable, Equatable {

        internal nonisolated struct Model: Codable, Sendable, Equatable {
            /// Null in every response observed so far — the display name is the only usable
            /// identifier, so nothing keys off this.
            internal let id: String?
            internal let displayName: String?

            private enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }

        internal let model: Model?

        // `surface` is deliberately not decoded: it has only ever been observed as null, so its
        // real shape is unknown. Declaring it as the wrong type would fail the whole decode the
        // day it arrives populated, and nothing here needs it.
    }

    internal nonisolated struct Limit: Codable, Sendable, Equatable {
        internal let kind: String?
        internal let group: String?
        internal let percent: Double?
        internal let severity: String?
        internal let resetsAt: Date?
        internal let isActive: Bool?
        internal let scope: Scope?

        private enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }

        /// Spelled out rather than synthesized so `scope` can default to nil: the vast majority of
        /// entries are unscoped, and every existing call site predates the field.
        internal init(
            kind: String?,
            group: String?,
            percent: Double?,
            severity: String?,
            resetsAt: Date?,
            isActive: Bool?,
            scope: Scope? = nil
        ) {
            self.kind = kind
            self.group = group
            self.percent = percent
            self.severity = severity
            self.resetsAt = resetsAt
            self.isActive = isActive
            self.scope = scope
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
