import XCTest
@testable import ClaudeUsageCore

final class ISO8601Tests: XCTestCase {
    func testParsesMicrosecondFraction() {
        // Real value captured from the live endpoint.
        let date = ISO8601.parse("2026-06-11T16:30:00.170987+00:00")
        XCTAssertNotNil(date)
        // 2026-06-11T16:30:00Z == 1781195400 (verify: date -u -j -f "%Y-%m-%dT%H:%M:%S" "2026-06-11T16:30:00" +%s)
        XCTAssertEqual(date!.timeIntervalSince1970, 1_781_195_400.170, accuracy: 0.01)
    }

    func testParsesMillisecondFraction() {
        XCTAssertNotNil(ISO8601.parse("2026-06-11T16:30:00.170+00:00"))
    }

    func testParsesNoFraction() {
        let date = ISO8601.parse("2026-06-11T16:30:00+00:00")
        XCTAssertEqual(date?.timeIntervalSince1970, 1_781_195_400)
    }

    func testParsesZuluSuffix() {
        XCTAssertNotNil(ISO8601.parse("2026-06-11T16:30:00Z"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(ISO8601.parse("not a date"))
    }
}
