import XCTest
@testable import ClaudeUsageCore

final class FakeListener: CallbackListening, @unchecked Sendable {
    var startResult: Result<UInt16, SignInError> = .success(4321)
    var callbackResult: Result<String, SignInError> = .success("code-1")
    var expectedState: String?
    var stopped = false

    func start(expectedState: String) async throws -> UInt16 {
        self.expectedState = expectedState
        return try startResult.get()
    }

    func waitForCallback(timeout: TimeInterval) async throws -> String { try callbackResult.get() }
    func stop() { stopped = true }
}

final class FakeExchanger: TokenExchanging, @unchecked Sendable {
    var exchangeResult: Result<TokenSet, TokenError> = .success(SignInFlowTests.tokens)
    var refreshResult: Result<TokenSet, TokenError> = .success(SignInFlowTests.tokens)
    var exchanges: [(code: String, verifier: String, state: String, redirectURI: String)] = []
    var refreshes: [String] = []
    var refreshDelay: Duration = .zero

    func exchange(code: String, codeVerifier: String, state: String, redirectURI: String) async throws -> TokenSet {
        exchanges.append((code, codeVerifier, state, redirectURI))
        return try exchangeResult.get()
    }

    func refresh(refreshToken: String) async throws -> TokenSet {
        refreshes.append(refreshToken)
        if refreshDelay > .zero { try? await Task.sleep(for: refreshDelay) }
        return try refreshResult.get()
    }
}

final class SignInFlowTests: XCTestCase {
    static let tokens = TokenSet(accessToken: "at", refreshToken: "rt",
                                 expiresAt: Date(timeIntervalSince1970: 1_789_000_000),
                                 scopes: ["user:profile"], accountEmail: nil)
    static let pkce = PKCE(verifierBytes: PKCETests.rfcVerifierBytes, stateBytes: [1, 2, 3])

    final class URLBox: @unchecked Sendable { var urls: [URL] = [] }

    private func run(listener: FakeListener, exchanger: FakeExchanger) async throws -> (TokenSet, [URL]) {
        let box = URLBox()
        let flow = SignInFlow(config: .claude, tokens: exchanger,
                              makeListener: { _ in listener }, makePKCE: { Self.pkce })
        let tokens = try await flow.run { box.urls.append($0) }
        return (tokens, box.urls)
    }

    func testHappyPath() async throws {
        let listener = FakeListener(), exchanger = FakeExchanger()
        let (tokens, urls) = try await run(listener: listener, exchanger: exchanger)
        XCTAssertEqual(tokens, Self.tokens)
        XCTAssertEqual(listener.expectedState, Self.pkce.state)
        XCTAssertEqual(urls, [AuthorizationRequest.url(config: .claude, pkce: Self.pkce, port: 4321)])
        XCTAssertEqual(exchanger.exchanges.count, 1)
        XCTAssertEqual(exchanger.exchanges[0].code, "code-1")
        XCTAssertEqual(exchanger.exchanges[0].verifier, Self.pkce.codeVerifier)
        XCTAssertEqual(exchanger.exchanges[0].state, Self.pkce.state)
        XCTAssertEqual(exchanger.exchanges[0].redirectURI, "http://localhost:4321/callback")
        XCTAssertTrue(listener.stopped)
    }

    func testListenerStartFailurePropagatesAndStops() async {
        let listener = FakeListener(); listener.startResult = .failure(.listenerFailed)
        await assertFails(listener: listener, exchanger: FakeExchanger(), with: .listenerFailed)
        XCTAssertTrue(listener.stopped)
    }

    func testCallbackErrorsPropagate() async {
        for failure in [SignInError.denied("access_denied"), .stateMismatch, .timedOut, .cancelled] {
            let listener = FakeListener(); listener.callbackResult = .failure(failure)
            let exchanger = FakeExchanger()
            await assertFails(listener: listener, exchanger: exchanger, with: failure)
            XCTAssertTrue(exchanger.exchanges.isEmpty)
            XCTAssertTrue(listener.stopped)
        }
    }

    func testExchangeFailureIsWrapped() async {
        let exchanger = FakeExchanger(); exchanger.exchangeResult = .failure(.http(500))
        await assertFails(listener: FakeListener(), exchanger: exchanger, with: .exchangeFailed(.http(500)))
    }

    private func assertFails(listener: FakeListener, exchanger: FakeExchanger, with expected: SignInError,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await run(listener: listener, exchanger: exchanger)
            XCTFail("expected throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SignInError, expected, file: file, line: line)
        }
    }
}
