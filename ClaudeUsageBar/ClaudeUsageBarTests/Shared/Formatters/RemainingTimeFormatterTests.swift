import Foundation
import Testing
@testable import ClaudeUsageBar

@Suite("RemainingTimeFormatter")
struct RemainingTimeFormatterTests {

    /// The regression this whole helper exists for: `RelativeDateTimeFormatter` rendered 4h55m as
    /// "in 4 hr", losing 55 minutes. Asserting on the digits rather than the localized unit names
    /// keeps the test independent of the run locale's abbreviations.
    @Test("Four hours and fifty-five minutes keeps both units, not just the hour")
    func fourHoursFiftyFiveMinutesKeepsMinutes() {
        let now: Date = Date()
        let resetsAt: Date = now.addingTimeInterval(4 * 3600 + 55 * 60)

        let text: String = RemainingTimeFormatter.duration(until: resetsAt, now: now)

        #expect(text.contains("4"))
        #expect(text.contains("55"))
    }

    @Test("A weekly window days away is rendered in days and hours, never in raw hours")
    func weeklyWindowUsesDaysAndHours() {
        let now: Date = Date()
        let resetsAt: Date = now.addingTimeInterval(3 * 86_400 + 5 * 3600)

        let text: String = RemainingTimeFormatter.duration(until: resetsAt, now: now)

        #expect(text.contains("3"))
        #expect(text.contains("5"))
        // 77 hours must not leak through as an hour count.
        #expect(!text.contains("77"))
    }

    /// The same weekly window in its final hours has to drop to hours+minutes on its own — the
    /// unit pair comes from the magnitude, not from which window asked.
    @Test("A window under a day away falls back to hours and minutes")
    func windowUnderOneDayUsesHoursAndMinutes() {
        let now: Date = Date()
        let resetsAt: Date = now.addingTimeInterval(4 * 3600 + 20 * 60)

        let text: String = RemainingTimeFormatter.duration(until: resetsAt, now: now)

        #expect(text.contains("4"))
        #expect(text.contains("20"))
    }

    @Test("An exact number of hours renders without a zero-minute component")
    func exactHoursDropsTheZeroMinutes() {
        let now: Date = Date()
        let resetsAt: Date = now.addingTimeInterval(2 * 3600)

        let text: String = RemainingTimeFormatter.duration(until: resetsAt, now: now)

        #expect(text.contains("2"))
        #expect(!text.contains("0"))
    }

    @Test("An exact number of days renders without a zero-hour component")
    func exactDaysDropsTheZeroHours() {
        let now: Date = Date()
        let resetsAt: Date = now.addingTimeInterval(2 * 86_400)

        let text: String = RemainingTimeFormatter.duration(until: resetsAt, now: now)

        #expect(text.contains("2"))
        #expect(!text.contains("0"))
    }

    @Test("Under a minute away, the text is never empty", arguments: [30.0, 1.0, 0.0])
    func subMinuteIntervalsAreNeverEmpty(secondsAway: TimeInterval) {
        let now: Date = Date()
        let resetsAt: Date = now.addingTimeInterval(secondsAway)

        let text: String = RemainingTimeFormatter.duration(until: resetsAt, now: now)

        #expect(!text.isEmpty)
        #expect(!text.contains("-"))
    }

    /// A reset whose timestamp already elapsed (a stale snapshot, or a clock a few seconds off)
    /// must not surface a negative duration while the next poll catches up.
    @Test("A reset already in the past never renders a negative duration")
    func pastResetNeverRendersNegative() {
        let now: Date = Date()
        let resetsAt: Date = now.addingTimeInterval(-90 * 60)

        let text: String = RemainingTimeFormatter.duration(until: resetsAt, now: now)

        #expect(!text.isEmpty)
        #expect(!text.contains("-"))
        #expect(!text.contains("90"))
    }
}
