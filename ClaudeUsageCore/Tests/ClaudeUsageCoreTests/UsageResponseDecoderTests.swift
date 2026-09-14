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

    // MARK: - Per-model weekly windows from `limits[]`

    /// Captured live from GET /api/oauth/usage on 2026-09-14. The Fable
    /// weekly limit only appears in `limits[]` as a `weekly_scoped` entry —
    /// there is no top-level `seven_day_fable` key.
    static let liveFixtureWithLimits = """
    {"five_hour":{"utilization":8.0,"resets_at":"2026-09-14T15:30:00.910731+00:00",\
    "limit_dollars":null,"used_dollars":null,"remaining_dollars":null,"locked_reason":null},\
    "seven_day":{"utilization":2.0,"resets_at":"2026-09-15T22:00:00.910755+00:00",\
    "limit_dollars":null,"used_dollars":null,"remaining_dollars":null,"locked_reason":null},\
    "seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null,\
    "seven_day_cowork":null,"seven_day_omelette":null,"tangelo":null,"iguana_necktie":null,\
    "omelette_promotional":null,"nimbus_quill":{"utilization":0.0,"resets_at":null,\
    "limit_dollars":null,"used_dollars":null,"remaining_dollars":null,"locked_reason":null},\
    "cinder_cove":null,"copper_kite":null,"harbor_lantern":null,"amber_ladder":null,\
    "juniper_tide":null,"extra_usage":{"is_enabled":false,"monthly_limit":null,\
    "used_credits":null,"utilization":null,"currency":null,"decimal_places":null,\
    "disabled_reason":null,"user_disabled":false,"spend_limit_reached":false,\
    "credits_ever_enabled":false,"daily":null,"weekly":null},\
    "limits":[{"kind":"session","group":"session","percent":8,"severity":"normal",\
    "resets_at":"2026-09-14T15:30:00.910731+00:00","scope":null,"is_active":true},\
    {"kind":"weekly_all","group":"weekly","percent":2,"severity":"normal",\
    "resets_at":"2026-09-15T22:00:00.910755+00:00","scope":null,"is_active":false},\
    {"kind":"weekly_scoped","group":"weekly","percent":4,"severity":"normal",\
    "resets_at":"2026-09-15T21:59:59.911047+00:00",\
    "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],\
    "spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"percent":0,\
    "severity":"normal","enabled":false,"disabled_reason":null,"cap":null,"balance":null,\
    "auto_reload":null,"disclaimer":"Usage credits cover you when you hit your plan limits.",\
    "can_purchase_credits":false,"can_toggle":false},"member_dashboard_available":false,\
    "seven_day_breakdown":null}
    """.data(using: .utf8)!

    func testDecodesFableWeeklyWindowFromLimits() throws {
        let snapshot = try UsageResponseDecoder.decode(Self.liveFixtureWithLimits)
        // `session` and `weekly_all` entries duplicate the fixed keys and must not add rows.
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "weekly_scoped:fable"])
        let fable = try XCTUnwrap(snapshot.windows.first { $0.id == "weekly_scoped:fable" })
        XCTAssertEqual(fable.label, "Week (Fable)")
        XCTAssertEqual(fable.utilization, 4.0)
        // 2026-09-15T21:59:59.911047+00:00
        XCTAssertEqual(fable.resetsAt.timeIntervalSince1970, 1_789_509_599.911, accuracy: 0.01)
    }

    func testScopedResetAsEpochSecondsIsAccepted() throws {
        let json = """
        {"limits":[{"kind":"weekly_scoped","percent":10,"resets_at":1789509599,\
        "scope":{"model":{"display_name":"Fable"}}}]}
        """.data(using: .utf8)!
        let snapshot = try UsageResponseDecoder.decode(json)
        let fable = try XCTUnwrap(snapshot.windows.first { $0.id == "weekly_scoped:fable" })
        XCTAssertEqual(fable.resetsAt.timeIntervalSince1970, 1_789_509_599, accuracy: 0.001)
    }

    func testScopedEntryWithoutModelNameIsSkipped() throws {
        let json = """
        {"limits":[{"kind":"weekly_scoped","percent":10,"resets_at":"2026-09-15T22:00:00+00:00","scope":null},\
        {"kind":"weekly_scoped","percent":10,"resets_at":"2026-09-15T22:00:00+00:00",\
        "scope":{"model":{"id":null,"display_name":null}}}]}
        """.data(using: .utf8)!
        let snapshot = try UsageResponseDecoder.decode(json)
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testMalformedLimitsElementDoesNotBreakDecoding() throws {
        let json = """
        {"limits":[42,{"kind":"weekly_scoped","percent":10,"resets_at":"2026-09-15T22:00:00+00:00",\
        "scope":{"model":{"display_name":"Fable"}}}]}
        """.data(using: .utf8)!
        let snapshot = try UsageResponseDecoder.decode(json)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly_scoped:fable"])
    }

    func testNonArrayLimitsIsIgnored() throws {
        let json = """
        {"five_hour":{"utilization":10.0,"resets_at":"2026-09-15T22:00:00+00:00"},"limits":{"oops":1}}
        """.data(using: .utf8)!
        let snapshot = try UsageResponseDecoder.decode(json)
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour"])
    }

    func testScopedOpusIsDroppedWhenFixedOpusWindowPresent() throws {
        let json = """
        {"seven_day_opus":{"utilization":12.0,"resets_at":"2026-09-16T22:00:00+00:00"},\
        "limits":[{"kind":"weekly_scoped","percent":12,"resets_at":"2026-09-16T22:00:00+00:00",\
        "scope":{"model":{"display_name":"Opus"}}}]}
        """.data(using: .utf8)!
        let snapshot = try UsageResponseDecoder.decode(json)
        XCTAssertEqual(snapshot.windows.map(\.id), ["seven_day_opus"])
    }
}
