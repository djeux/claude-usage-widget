import XCTest
@testable import ClaudeUsageCore

final class OAuthTokenClientTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_789_000_000)

    final class Recorder: @unchecked Sendable {
        var request: URLRequest?
    }

    private func makeClient(status: Int, body: String, recorder: Recorder = Recorder()) -> OAuthTokenClient {
        OAuthTokenClient(config: .claude, transport: { request in
            recorder.request = request
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }, now: { Self.now })
    }

    private func bodyJSON(_ request: URLRequest?) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: String])
    }

    static let fullResponse = """
    {"token_type":"Bearer","access_token":"at-1","refresh_token":"rt-1","expires_in":28800,\
    "scope":"user:profile","account":{"uuid":"u1","email_address":"me@example.com"}}
    """

    func testExchangeSendsExpectedBodyAndDecodes() async throws {
        let recorder = Recorder()
        let client = makeClient(status: 200, body: Self.fullResponse, recorder: recorder)
        let tokens = try await client.exchange(code: "code-1", codeVerifier: "ver", state: "st",
                                               redirectURI: "http://localhost:4242/callback")
        XCTAssertEqual(recorder.request?.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(recorder.request?.httpMethod, "POST")
        XCTAssertEqual(recorder.request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try bodyJSON(recorder.request), [
            "grant_type": "authorization_code",
            "code": "code-1",
            "redirect_uri": "http://localhost:4242/callback",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "code_verifier": "ver",
            "state": "st",
        ])
        XCTAssertEqual(tokens, TokenSet(accessToken: "at-1", refreshToken: "rt-1",
                                        expiresAt: Self.now.addingTimeInterval(28800),
                                        scopes: ["user:profile"], accountEmail: "me@example.com"))
    }

    func testRefreshSendsExpectedBody() async throws {
        let recorder = Recorder()
        let client = makeClient(status: 200, body: Self.fullResponse, recorder: recorder)
        _ = try await client.refresh(refreshToken: "rt-old")
        XCTAssertEqual(try bodyJSON(recorder.request), [
            "grant_type": "refresh_token",
            "refresh_token": "rt-old",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile",
        ])
    }

    func testRefreshKeepsOldRefreshTokenWhenMissing() async throws {
        let client = makeClient(status: 200, body: #"{"access_token":"at-2","expires_in":60}"#)
        let tokens = try await client.refresh(refreshToken: "rt-old")
        XCTAssertEqual(tokens.refreshToken, "rt-old")
        XCTAssertEqual(tokens.accessToken, "at-2")
        XCTAssertEqual(tokens.scopes, [])
        XCTAssertNil(tokens.accountEmail)
    }

    func testMissingExpiresInAssumesOneHour() async throws {
        let client = makeClient(status: 200, body: #"{"access_token":"at-3","refresh_token":"rt-3"}"#)
        let tokens = try await client.exchange(code: "c", codeVerifier: "v", state: "s", redirectURI: "r")
        XCTAssertEqual(tokens.expiresAt, Self.now.addingTimeInterval(3600))
    }

    func testInvalidGrantMapsToInvalidGrant() async {
        let client = makeClient(status: 400, body: #"{"error":"invalid_grant","error_description":"expired"}"#)
        await assertThrows(try await client.refresh(refreshToken: "rt"), .invalidGrant)
    }

    func test401OnRefreshIsInvalidGrant() async {
        let client = makeClient(status: 401, body: "")
        await assertThrows(try await client.refresh(refreshToken: "rt"), .invalidGrant)
    }

    func testOtherHTTPErrorMapsToHTTP() async {
        let client = makeClient(status: 500, body: "boom")
        await assertThrows(try await client.refresh(refreshToken: "rt"), .http(500))
    }

    func testBadJSONMapsToDecoding() async {
        let client = makeClient(status: 200, body: "not json")
        await assertThrows(try await client.refresh(refreshToken: "rt"), .decoding)
    }

    func testTransportFailureMapsToNetwork() async {
        let client = OAuthTokenClient(config: .claude, transport: { _ in throw URLError(.notConnectedToInternet) },
                                      now: { Self.now })
        do {
            _ = try await client.refresh(refreshToken: "rt")
            XCTFail("expected throw")
        } catch {
            guard case .network = error as? TokenError else { return XCTFail("got \(error)") }
        }
    }

    private func assertThrows(_ body: @autoclosure () async throws -> TokenSet, _ expected: TokenError,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TokenError, expected, file: file, line: line)
        }
    }
}
