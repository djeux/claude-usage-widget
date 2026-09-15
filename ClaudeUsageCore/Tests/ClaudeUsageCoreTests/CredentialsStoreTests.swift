import XCTest
@testable import ClaudeUsageCore

final class CredentialsStoreTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_781_179_200) // 2026-06-11T12:00:00Z

    private static func json(expiresAtMs: Double) -> Data {
        """
        {"claudeAiOauth":{"accessToken":"sk-test-token","refreshToken":"sk-refresh",\
        "expiresAt":\(expiresAtMs),"scopes":["user:inference"],"subscriptionType":"max"}}
        """.data(using: .utf8)!
    }

    private func store(_ result: Result<Data, KeychainError>) -> KeychainCredentialsStore {
        let keychain = FakeKeychain()
        switch result {
        case .success(let data): keychain.items["Claude Code-credentials|"] = data
        case .failure(let error): keychain.failure = error
        }
        return KeychainCredentialsStore(keychain: keychain)
    }

    func testReadsValidToken() throws {
        let future = (Self.now.timeIntervalSince1970 + 3600) * 1000
        let credentials = try store(.success(Self.json(expiresAtMs: future))).read(now: Self.now)
        XCTAssertEqual(credentials.accessToken, "sk-test-token")
    }

    func testExpiredTokenThrows() {
        let past = (Self.now.timeIntervalSince1970 - 60) * 1000
        XCTAssertThrowsError(try store(.success(Self.json(expiresAtMs: past))).read(now: Self.now)) {
            XCTAssertEqual($0 as? CredentialsError, .expired)
        }
    }

    func testMissingItemMapsToNotLoggedIn() {
        XCTAssertThrowsError(try store(.failure(.itemNotFound)).read(now: Self.now)) {
            XCTAssertEqual($0 as? CredentialsError, .notLoggedIn)
        }
    }

    func testAccessDeniedMapsThrough() {
        XCTAssertThrowsError(try store(.failure(.accessDenied)).read(now: Self.now)) {
            XCTAssertEqual($0 as? CredentialsError, .accessDenied)
        }
    }

    func testOtherKeychainErrorMapsToKeychainCase() {
        XCTAssertThrowsError(try store(.failure(.os(-25293))).read(now: Self.now)) {
            XCTAssertEqual($0 as? CredentialsError, .keychain(-25293))
        }
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try store(.success(Data("{}".utf8))).read(now: Self.now)) {
            XCTAssertEqual($0 as? CredentialsError, .malformed)
        }
    }
}
