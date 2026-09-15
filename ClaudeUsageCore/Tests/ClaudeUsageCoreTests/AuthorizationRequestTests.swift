import XCTest
@testable import ClaudeUsageCore

final class AuthorizationRequestTests: XCTestCase {
    func testBuildsAuthorizeURLWithAllParameters() throws {
        let pkce = PKCE(verifierBytes: PKCETests.rfcVerifierBytes, stateBytes: [9, 9, 9])
        let url = AuthorizationRequest.url(config: .claude, pkce: pkce, port: 4242)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(components.path, "/cai/oauth/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "code": "true",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "response_type": "code",
            "redirect_uri": "http://localhost:4242/callback",
            "scope": "user:profile",
            "code_challenge": PKCETests.rfcChallenge,
            "code_challenge_method": "S256",
            "state": "CQkJ",
        ])
    }
}
