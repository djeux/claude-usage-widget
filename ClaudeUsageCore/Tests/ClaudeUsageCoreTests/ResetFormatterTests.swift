import XCTest
@testable import ClaudeUsageCore

final class ResetFormatterTests: XCTestCase {
    // Fixed UTC calendar so tests don't depend on the machine's locale/zone.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // 2026-06-11T12:00:00Z (a Thursday)
    static let now = Date(timeIntervalSince1970: 1_781_179_200)

    private func format(secondsAhead: TimeInterval) -> String {
        ResetFormatter.string(for: Self.now.addingTimeInterval(secondsAhead),
                              now: Self.now, calendar: Self.utcCalendar)
    }

    func testUnder24HoursWithHours() {
        XCTAssertEqual(format(secondsAhead: 2 * 3600 + 14 * 60), "resets in 2h 14m")
    }

    func testUnder1Hour() {
        XCTAssertEqual(format(secondsAhead: 45 * 60), "resets in 45m")
    }

    func testPastDate() {
        XCTAssertEqual(format(secondsAhead: -30), "resets soon")
    }

    func testOver24HoursShowsWeekdayAndTime() {
        // 2026-06-16T09:00:00Z is a Tuesday.
        let tuesday = Date(timeIntervalSince1970: 1_781_600_400)
        XCTAssertEqual(
            ResetFormatter.string(for: tuesday, now: Self.now, calendar: Self.utcCalendar),
            "resets Tue 09:00"
        )
    }
}
