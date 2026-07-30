import Foundation

nonisolated extension JSONDecoder.DateDecodingStrategy {

    /// Decodes ISO-8601 timestamps with up to 6 fractional-second digits, e.g.
    /// `2026-07-30T06:29:59.393695+00:00`, falling back to no-fraction timestamps.
    internal static let fractionalISO8601: JSONDecoder.DateDecodingStrategy = .custom(decodeFractionalISO8601)

    @Sendable
    nonisolated private static func decodeFractionalISO8601(_ decoder: any Decoder) throws -> Date {
        let raw: String = try decoder.singleValueContainer().decode(String.self)

        let fractional: ISO8601DateFormatter = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let whole: ISO8601DateFormatter = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        if let date = whole.date(from: raw) { return date }

        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "timestamp ilegible: \(raw)")
        )
    }
}
