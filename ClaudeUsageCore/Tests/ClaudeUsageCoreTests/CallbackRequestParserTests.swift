import XCTest
@testable import ClaudeUsageCore

final class CallbackRequestParserTests: XCTestCase {
    private func parse(_ line: String) -> CallbackRequest {
        CallbackRequestParser.parse(requestLine: line, callbackPath: "/callback")
    }

    func testParsesCodeAndState() {
        XCTAssertEqual(parse("GET /callback?code=abc123&state=xyz HTTP/1.1"),
                       .success(code: "abc123", state: "xyz"))
    }

    func testErrorParameterIsDenied() {
        XCTAssertEqual(parse("GET /callback?error=access_denied&state=xyz HTTP/1.1"),
                       .denied(error: "access_denied"))
    }

    func testOtherPathIsNotCallback() {
        XCTAssertEqual(parse("GET /favicon.ico HTTP/1.1"), .notCallback)
        XCTAssertEqual(parse("GET / HTTP/1.1"), .notCallback)
    }

    func testMissingCodeOrStateIsNotCallback() {
        XCTAssertEqual(parse("GET /callback?code=abc HTTP/1.1"), .notCallback)
        XCTAssertEqual(parse("GET /callback?state=abc HTTP/1.1"), .notCallback)
        XCTAssertEqual(parse("GET /callback?code=&state=x HTTP/1.1"), .notCallback)
    }

    func testMalformedLinesDoNotCrash() {
        XCTAssertEqual(parse(""), .notCallback)
        XCTAssertEqual(parse("GET"), .notCallback)
        XCTAssertEqual(parse("POST /callback?code=a&state=b HTTP/1.1"), .notCallback)
        XCTAssertEqual(parse("GET /call back?code=a&state=b HTTP/1.1"), .notCallback)
    }
}
