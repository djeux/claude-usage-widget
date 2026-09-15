import XCTest
@testable import ClaudeUsageCore

final class PKCETests: XCTestCase {
    // RFC 7636 Appendix B vectors.
    static let rfcVerifierBytes: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125,
                                            216, 173, 187, 186, 22, 212, 37, 77, 105, 214, 191, 240,
                                            91, 88, 5, 88, 83, 132, 141, 121]
    static let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    static let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    func testVerifierIsBase64URLOfBytes() {
        let pkce = PKCE(verifierBytes: Self.rfcVerifierBytes, stateBytes: [0, 1, 2])
        XCTAssertEqual(pkce.codeVerifier, Self.rfcVerifier)
        XCTAssertEqual(pkce.state, "AAEC")
    }

    func testChallengeMatchesRFCVector() {
        XCTAssertEqual(PKCE.challenge(for: Self.rfcVerifier), Self.rfcChallenge)
        XCTAssertEqual(PKCE(verifierBytes: Self.rfcVerifierBytes, stateBytes: [0]).codeChallenge, Self.rfcChallenge)
    }

    func testRandomInitProducesValidLengthAndDiffers() {
        let a = PKCE(), b = PKCE()
        XCTAssertEqual(a.codeVerifier.count, 43)
        XCTAssertEqual(a.state.count, 43)
        XCTAssertNotEqual(a.codeVerifier, b.codeVerifier)
        XCTAssertNotEqual(a.state, b.state)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(a.codeVerifier.allSatisfy { allowed.contains($0) })
    }

    func testConfigurationRedirectURI() {
        XCTAssertEqual(OAuthConfiguration.claude.redirectURI(port: 51234), "http://localhost:51234/callback")
        XCTAssertEqual(OAuthConfiguration.claude.scopes, ["user:profile"])
        XCTAssertEqual(OAuthConfiguration.claude.clientID, "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }
}
