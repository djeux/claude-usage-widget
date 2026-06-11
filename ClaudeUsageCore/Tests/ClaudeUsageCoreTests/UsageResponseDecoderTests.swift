import XCTest
@testable import ClaudeUsageCore

final class UsageResponseDecoderTests: XCTestCase {
    /// Captured live from GET /api/oauth/usage on 2026-06-11.
    static let liveFixture = """
    {"five_hour":{"utilization":23.0,"resets_at":"2026-06-11T16:30:00.170987+00:00"},\
    "seven_day":{"utilization":19.0,"resets_at":"2026-06-16T22:00:00.171009+00:00"},\
    "seven_day_oauth_apps":null,"seven_day_opus":null,\
    "seven_day_sonnet":{"utilization":0.0,"resets_at":"2026-06-16T22:00:01.171020+00:00"},\
    "seven_day_cowork":null,"seven_day_omelette":null,"tangelo":null,\
    "iguana_necktie":null,"omelette_promotional":null,"cinder_cove":null,\
    "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,\
    "utilization":null,"currency":null,"disabled_reason":null}}
    """.data(using: .utf8)!

    func testDecodesLiveFixture() throws {
        let snapshot = try UsageResponseDecoder.decode(Self.liveFixture)
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(snapshot.windows[0].label, "Session (5h)")
        XCTAssertEqual(snapshot.windows[0].utilization, 23.0)
        // 2026-06-11T16:30:00.170987+00:00 — closes the decoder↔ISO8601 seam.
        XCTAssertEqual(snapshot.windows[0].resetsAt.timeIntervalSince1970,
                       1_781_195_400.170, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[1].label, "Week (all models)")
        XCTAssertEqual(snapshot.windows[2].label, "Week (Sonnet)")
    }

    func testNullAndUnknownKeysAreSkipped() throws {
        let json = """
        {"five_hour":null,"seven_day":{"utilization":50.0,"resets_at":"2026-06-16T22:00:00+00:00"},\
        "brand_new_key":{"whatever":1}}
        """.data(using: .utf8)!
        let snapshot = try UsageResponseDecoder.decode(json)
        XCTAssertEqual(snapshot.windows.map(\.id), ["seven_day"])
    }

    func testOpusWindowDecodesWhenPresent() throws {
        let json = """
        {"seven_day_opus":{"utilization":12.0,"resets_at":"2026-06-16T22:00:00+00:00"}}
        """.data(using: .utf8)!
        let snapshot = try UsageResponseDecoder.decode(json)
        XCTAssertEqual(snapshot.windows.map(\.label), ["Week (Opus)"])
    }

    func testWindowWithUnparseableDateIsSkipped() throws {
        let json = """
        {"five_hour":{"utilization":10.0,"resets_at":"garbage"}}
        """.data(using: .utf8)!
        let snapshot = try UsageResponseDecoder.decode(json)
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try UsageResponseDecoder.decode(Data("not json".utf8)))
    }
}
