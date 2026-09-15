import XCTest
@testable import ClaudeUsageCore

final class CallbackListenerTests: XCTestCase {
    private func get(_ port: UInt16, _ pathAndQuery: String) async throws -> (Int, String) {
        let url = URL(string: "http://127.0.0.1:\(port)\(pathAndQuery)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    func testDeliversCodeForMatchingStateAndHidesCode() async throws {
        let listener = CallbackListener(callbackPath: "/callback")
        let port = try await listener.start(expectedState: "s1")
        defer { listener.stop() }
        XCTAssertNotEqual(port, 0)

        async let code = listener.waitForCallback(timeout: 5)
        let (status, body) = try await get(port, "/callback?code=abc&state=s1")
        XCTAssertEqual(status, 200)
        XCTAssertFalse(body.contains("abc"))
        XCTAssertTrue(body.contains("Signed in"))
        let received = try await code
        XCTAssertEqual(received, "abc")
    }

    func testNonCallbackGets404AndListenerKeepsWaiting() async throws {
        let listener = CallbackListener(callbackPath: "/callback")
        let port = try await listener.start(expectedState: "s1")
        defer { listener.stop() }

        async let code = listener.waitForCallback(timeout: 5)
        let (status, _) = try await get(port, "/favicon.ico")
        XCTAssertEqual(status, 404)
        _ = try await get(port, "/callback?code=later&state=s1")
        let received = try await code
        XCTAssertEqual(received, "later")
    }

    func testStateMismatchFails() async throws {
        let listener = CallbackListener(callbackPath: "/callback")
        let port = try await listener.start(expectedState: "s1")
        defer { listener.stop() }

        async let code = listener.waitForCallback(timeout: 5)
        let (status, _) = try await get(port, "/callback?code=abc&state=wrong")
        XCTAssertEqual(status, 400)
        do {
            _ = try await code
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? SignInError, .stateMismatch)
        }
    }

    func testDeniedFails() async throws {
        let listener = CallbackListener(callbackPath: "/callback")
        let port = try await listener.start(expectedState: "s1")
        defer { listener.stop() }

        async let code = listener.waitForCallback(timeout: 5)
        _ = try await get(port, "/callback?error=access_denied&state=s1")
        do {
            _ = try await code
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? SignInError, .denied("access_denied"))
        }
    }

    func testTimesOut() async throws {
        let listener = CallbackListener(callbackPath: "/callback")
        _ = try await listener.start(expectedState: "s1")
        defer { listener.stop() }
        do {
            _ = try await listener.waitForCallback(timeout: 0.2)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? SignInError, .timedOut)
        }
    }

    func testCallbackBeforeWaitIsBuffered() async throws {
        let listener = CallbackListener(callbackPath: "/callback")
        let port = try await listener.start(expectedState: "s1")
        defer { listener.stop() }
        _ = try await get(port, "/callback?code=early&state=s1")
        let received = try await listener.waitForCallback(timeout: 1)
        XCTAssertEqual(received, "early")
    }
}
