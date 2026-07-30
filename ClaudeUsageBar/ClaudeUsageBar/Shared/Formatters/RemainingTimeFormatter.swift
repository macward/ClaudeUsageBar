import Foundation

/// Formats "how long until X" for the popover.
///
/// `RelativeDateTimeFormatter` can't do this job: by design it collapses to a single unit, so
/// 4h55m until the session reset renders as "in 4 hr" — nearly an hour short of the truth, and
/// visibly wrong next to Claude Desktop's "Resets in 4 hr 55 min". `DateComponentsFormatter`
/// keeps two units, which is the precision this popover needs.
///
/// The unit pair is picked from the magnitude of the interval rather than from the caller's
/// window kind, so both the 5-hour session and the weekly window get a sensible scale without
/// anyone having to say which is which: a weekly window three days out reads "3 d 5 h", and the
/// same window in its final hours reads "4 h 20 min".
internal nonisolated enum RemainingTimeFormatter {

    /// Anything under a minute has no useful two-unit rendering — and a reset that just elapsed
    /// (or a clock skewed a few seconds past it) must not render as an empty string or a negative
    /// duration while the next poll catches up.
    private static let subMinuteText: String = "menos de 1 min"

    /// Below this, the pair is hours+minutes; at or above it, days+hours.
    private static let dayInSeconds: TimeInterval = 86_400

    // MARK: - Public Methods

    /// The time left until `date`, as a bare duration ("4 h 55 min", "3 d 5 h") for the caller to
    /// place in its own sentence. Never returns an empty string, and never renders a zero unit:
    /// an exact two hours is "2 h", not "2 h 0 min".
    internal static func duration(until date: Date, now: Date = Date()) -> String {
        let interval: TimeInterval = date.timeIntervalSince(now)
        guard interval >= 60 else { return subMinuteText }

        let formatter: DateComponentsFormatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= dayInSeconds ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        // Drops any component that came out zero, so the two allowed units are a ceiling and not
        // a quota.
        formatter.zeroFormattingBehavior = .dropAll

        // `string(from:)` is documented as failable, and it also yields an empty string when every
        // allowed unit rounds away — both collapse to the same guard so the caller can rely on
        // getting something printable.
        guard let formatted: String = formatter.string(from: interval), !formatted.isEmpty else {
            return subMinuteText
        }
        return formatted
    }
}
