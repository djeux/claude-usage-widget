import XCTest
@testable import ClaudeUsageCore

/// In-memory keychain keyed by service+account.
final class FakeKeychain: KeychainAccessing, @unchecked Sendable {
    var items: [String: Data] = [:]
    var failure: KeychainError?

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func data(service: String, account: String) throws -> Data {
        if let failure { throw failure }
        guard let data = items[key(service, account)] else { throw KeychainError.itemNotFound }
        return data
    }

    func set(_ data: Data, service: String, account: String) throws {
        if let failure { throw failure }
        items[key(service, account)] = data
    }

    func delete(service: String, account: String) throws {
        if let failure { throw failure }
        guard items.removeValue(forKey: key(service, account)) != nil else { throw KeychainError.itemNotFound }
    }
}

final class KeychainTokenStoreTests: XCTestCase {
    static let tokens = TokenSet(accessToken: "at", refreshToken: "rt",
                                 expiresAt: Date(timeIntervalSince1970: 1_789_000_000),
                                 scopes: ["user:profile"], accountEmail: "me@example.com")

    func testLoadReturnsNilWhenEmpty() throws {
        XCTAssertNil(try KeychainTokenStore(keychain: FakeKeychain()).load())
    }

    func testRoundTrip() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(keychain: keychain)
        try store.save(Self.tokens)
        XCTAssertEqual(try store.load(), Self.tokens)
        XCTAssertEqual(keychain.items.keys.first, "Claude Usage|claude.ai")
    }

    func testClearRemovesItemAndIsIdempotent() throws {
        let store = KeychainTokenStore(keychain: FakeKeychain())
        try store.save(Self.tokens)
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.clear())
    }

    func testCorruptDataIsMalformed() {
        let keychain = FakeKeychain()
        keychain.items["Claude Usage|claude.ai"] = Data("{}".utf8)
        XCTAssertThrowsError(try KeychainTokenStore(keychain: keychain).load()) {
            XCTAssertEqual($0 as? CredentialsError, .malformed)
        }
    }

    func testAccessDeniedMapsThrough() {
        let keychain = FakeKeychain()
        keychain.failure = .accessDenied
        XCTAssertThrowsError(try KeychainTokenStore(keychain: keychain).load()) {
            XCTAssertEqual($0 as? CredentialsError, .accessDenied)
        }
    }

    func testOSErrorMapsToKeychainCase() {
        let keychain = FakeKeychain()
        keychain.failure = .os(-25293)
        XCTAssertThrowsError(try KeychainTokenStore(keychain: keychain).save(Self.tokens)) {
            XCTAssertEqual($0 as? CredentialsError, .keychain(-25293))
        }
    }
}
