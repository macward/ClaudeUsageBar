import Foundation
import Testing
@testable import ClaudeUsageBar

@Suite("UsageSnapshot decoding")
struct UsageSnapshotDecodingTests {

    @Test("Decodes the full response with five_hour, seven_day and limits")
    func decodesFullResponse() throws {
        let data: Data = try FixtureLoader.data(named: "usage-full")
        let snapshot: UsageSnapshot = try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)

        #expect(snapshot.fiveHour?.utilization == 55.0)
        #expect(snapshot.sevenDay?.utilization == 18.0)
        #expect(snapshot.limits?.count == 2)
        #expect(snapshot.limits?.first?.isActive == true)
    }

    @Test("Decodes a minimal response with only five_hour")
    func decodesMinimalResponse() throws {
        let data: Data = try FixtureLoader.data(named: "usage-minimal")
        let snapshot: UsageSnapshot = try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)

        #expect(snapshot.fiveHour?.utilization == 42.0)
        #expect(snapshot.sevenDay == nil)
        #expect(snapshot.limits == nil)
    }

    @Test("Ignores unknown internal feature-flag keys without failing")
    func decodesResponseWithUnknownKeys() throws {
        let data: Data = try FixtureLoader.data(named: "usage-unknown-keys")
        let snapshot: UsageSnapshot = try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)

        #expect(snapshot.fiveHour?.utilization == 30.0)
        #expect(snapshot.limits?.first?.kind == "session")
    }

    @Test("Decodes timestamps without fractional seconds")
    func decodesTimestampWithoutFraction() throws {
        let data: Data = try FixtureLoader.data(named: "usage-no-fraction")
        let snapshot: UsageSnapshot = try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)

        let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(snapshot.fiveHour?.resetsAt == formatter.date(from: "2026-07-30T12:00:00+00:00"))
    }

    @Test("Decodes fractional timestamps to the correct Date")
    func decodesFractionalTimestamp() throws {
        let data: Data = try FixtureLoader.data(named: "usage-full")
        let snapshot: UsageSnapshot = try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)

        let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(snapshot.fiveHour?.resetsAt == formatter.date(from: "2026-07-30T06:29:59.393695+00:00"))
    }

    /// Captured verbatim from the live endpoint, per-model cap included. It is the only fixture
    /// carrying `limits[].scope`, and it doubles as the real-world shape check: null-valued
    /// internal keys, `spend`, `extra_usage` and all.
    @Test("Decodes the real response carrying a per-model scoped limit")
    func decodesScopedLimitResponse() throws {
        let data: Data = try FixtureLoader.data(named: "usage-scoped-limits")
        let snapshot: UsageSnapshot = try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)

        #expect(snapshot.limits?.count == 3)

        let scoped: UsageSnapshot.Limit? = snapshot.limits?.first { $0.kind == "weekly_scoped" }
        #expect(scoped?.percent == 8)
        #expect(scoped?.group == "weekly")
        #expect(scoped?.scope?.model?.displayName == "Fable")
        #expect(scoped?.scope?.model?.id == nil)
    }

    /// The flag the popover used to filter on: the live session window arrives `false`, which is
    /// why nothing keys off it any more. Pinned here so a change in that behaviour is noticed.
    @Test("The live session limit arrives flagged is_active false")
    func sessionLimitArrivesInactive() throws {
        let data: Data = try FixtureLoader.data(named: "usage-scoped-limits")
        let snapshot: UsageSnapshot = try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)

        let session: UsageSnapshot.Limit? = snapshot.limits?.first { $0.kind == "session" }
        #expect(session?.isActive == false)
        #expect(session?.percent == 22)
    }

    /// An unscoped entry must decode with `scope` nil rather than an empty ``UsageSnapshot/Scope``.
    @Test("An unscoped limit decodes with a nil scope")
    func unscopedLimitHasNilScope() throws {
        let data: Data = try FixtureLoader.data(named: "usage-full")
        let snapshot: UsageSnapshot = try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)

        #expect(snapshot.limits?.first?.scope == nil)
    }

    @Test("An empty object decodes with every field nil")
    func decodesEmptyObjectToAllNilFields() throws {
        let data: Data = Data("{}".utf8)
        let snapshot: UsageSnapshot = try JSONDecoder.usageSnapshot.decode(UsageSnapshot.self, from: data)

        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay == nil)
        #expect(snapshot.limits == nil)
    }
}
