import XCTest
@testable import ClaudeUsageCore

final class SeverityTests: XCTestCase {
    func testBelow60IsNormal() {
        XCTAssertEqual(Severity.forUtilization(0), .normal)
        XCTAssertEqual(Severity.forUtilization(59.9), .normal)
    }

    func testAt60IsWarning() {
        XCTAssertEqual(Severity.forUtilization(60), .warning)
        XCTAssertEqual(Severity.forUtilization(94.9), .warning)
    }

    func testAt95IsCritical() {
        XCTAssertEqual(Severity.forUtilization(95), .critical)
        XCTAssertEqual(Severity.forUtilization(100), .critical)
    }
}
