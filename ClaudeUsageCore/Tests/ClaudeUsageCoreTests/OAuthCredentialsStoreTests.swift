import XCTest
@testable import ClaudeUsageCore

final class OAuthCredentialsStoreTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_789_000_000)
    static let valid = TokenSet(accessToken: "at-1", refreshToken: "rt-1",
                                expiresAt: now.addingTimeInterval(3600), scopes: ["user:profile"], accountEmail: nil)
    static let nearExpiry = TokenSet(accessToken: "at-old", refreshToken: "rt-old",
                                     expiresAt: now.addingTimeInterval(30), scopes: [], accountEmail: nil)
    static let refreshed = TokenSet(accessToken: "at-new", refreshToken: "rt-new",
                                    expiresAt: now.addingTimeInterval(7200), scopes: [], accountEmail: nil)

    private var keychain = FakeKeychain()
    private var exchanger = FakeExchanger()

    private func makeStore(seed: TokenSet?) throws -> OAuthCredentialsStore {
        keychain = FakeKeychain()
        exchanger = FakeExchanger()
        exchanger.refreshResult = .success(Self.refreshed)
        let tokenStore = KeychainTokenStore(keychain: keychain)
        if let seed { try tokenStore.save(seed) }
        let flow = SignInFlow(config: .claude, tokens: exchanger,
                              makeListener: { _ in FakeListener() },
                              makePKCE: { SignInFlowTests.pkce })
        return OAuthCredentialsStore(store: tokenStore, tokens: exchanger, config: .claude, flow: flow)
    }

    func testNoTokensThrowsNotLoggedIn() async throws {
        let store = try makeStore(seed: nil)
        await assertThrows(try await store.read(now: Self.now), .notLoggedIn)
    }

    func testValidTokenReturnedWithoutRefresh() async throws {
        let store = try makeStore(seed: Self.valid)
        let credentials = try await store.read(now: Self.now)
        XCTAssertEqual(credentials, Credentials(accessToken: "at-1", expiresAt: Self.valid.expiresAt))
        XCTAssertTrue(exchanger.refreshes.isEmpty)
    }

    func testNearExpiryRefreshesAndSaves() async throws {
        let store = try makeStore(seed: Self.nearExpiry)
        let credentials = try await store.read(now: Self.now)
        XCTAssertEqual(credentials.accessToken, "at-new")
        XCTAssertEqual(exchanger.refreshes, ["rt-old"])
        XCTAssertEqual(try KeychainTokenStore(keychain: keychain).load(), Self.refreshed)
        // Second read uses the cached fresh token.
        _ = try await store.read(now: Self.now)
        XCTAssertEqual(exchanger.refreshes.count, 1)
    }

    func testConcurrentReadsShareOneRefresh() async throws {
        let store = try makeStore(seed: Self.nearExpiry)
        exchanger.refreshDelay = .milliseconds(50)
        async let a = store.read(now: Self.now)
        async let b = store.read(now: Self.now)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first.accessToken, "at-new")
        XCTAssertEqual(second.accessToken, "at-new")
        XCTAssertEqual(exchanger.refreshes.count, 1)
    }

    func testInvalidGrantClearsAndThrowsNotLoggedIn() async throws {
        let store = try makeStore(seed: Self.nearExpiry)
        exchanger.refreshResult = .failure(.invalidGrant)
        await assertThrows(try await store.read(now: Self.now), .notLoggedIn)
        XCTAssertTrue(keychain.items.isEmpty)
        await assertThrows(try await store.read(now: Self.now), .notLoggedIn)
        XCTAssertEqual(exchanger.refreshes.count, 1)
    }

    func testNetworkFailureThrowsRefreshFailedAndKeepsTokens() async throws {
        let store = try makeStore(seed: Self.nearExpiry)
        exchanger.refreshResult = .failure(.network("offline"))
        await assertThrows(try await store.read(now: Self.now), .refreshFailed)
        XCTAssertEqual(try KeychainTokenStore(keychain: keychain).load(), Self.nearExpiry)
        // Retry succeeds later.
        exchanger.refreshResult = .success(Self.refreshed)
        let recovered = try await store.read(now: Self.now)
        XCTAssertEqual(recovered.accessToken, "at-new")
    }

    func testInvalidateForcesRefresh() async throws {
        let store = try makeStore(seed: Self.valid)
        _ = try await store.read(now: Self.now)
        await store.invalidate()
        let refreshed = try await store.read(now: Self.now)
        XCTAssertEqual(refreshed.accessToken, "at-new")
        XCTAssertEqual(exchanger.refreshes, ["rt-1"])
    }

    func testSignInSavesTokens() async throws {
        let store = try makeStore(seed: nil)
        exchanger.exchangeResult = .success(Self.valid)
        try await store.signIn { _ in }
        let signedIn = try await store.read(now: Self.now)
        XCTAssertEqual(signedIn.accessToken, "at-1")
        XCTAssertEqual(try KeychainTokenStore(keychain: keychain).load(), Self.valid)
    }

    func testSignInKeychainFailureIsStoreFailed() async throws {
        let store = try makeStore(seed: nil)
        exchanger.exchangeResult = .success(Self.valid)
        keychain.failure = .os(-25293)
        do {
            try await store.signIn { _ in }
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? SignInError, .storeFailed)
        }
        await assertThrows(try await store.read(now: Self.now), .keychain(-25293))
    }

    func testSignOutClears() async throws {
        let store = try makeStore(seed: Self.valid)
        _ = try await store.read(now: Self.now)
        await store.signOut()
        XCTAssertTrue(keychain.items.isEmpty)
        await assertThrows(try await store.read(now: Self.now), .notLoggedIn)
    }

    private func assertThrows(_ body: @autoclosure () async throws -> Credentials, _ expected: CredentialsError,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CredentialsError, expected, file: file, line: line)
        }
    }
}
