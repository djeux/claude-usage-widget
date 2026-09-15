# App-Owned OAuth Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the read of Claude Code's keychain item with the app's own OAuth PKCE login, app-owned token storage, and silent refresh, so the app never triggers a keychain prompt.

**Architecture:** New `OAuth/` group in `ClaudeUsageCore` holds pure pieces (PKCE, authorize URL, callback parser), a loopback `CallbackListener` (Network framework), an `OAuthTokenClient` (exchange/refresh), a `KeychainTokenStore` (app-owned item), a `SignInFlow` orchestrator, and an `OAuthCredentialsStore` actor that hands the view model a valid token. `UsageViewModel` gains signed-out / signing-in phases and sign-in/out actions; the popover gets the matching UI. The old `KeychainCredentialsStore` is deleted.

**Tech Stack:** Swift 5.10 package (macOS 14+), XCTest, Foundation, CryptoKit, Network, Security. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-14-app-owned-oauth-login-design.md`

## Global Constraints

- Platform floor: macOS 14 (`Package.swift` `platforms: [.macOS(.v14)]`, `MACOSX_DEPLOYMENT_TARGET = 14.0`). No new dependencies.
- Authorize URL `https://claude.com/cai/oauth/authorize`; token URL `https://platform.claude.com/v1/oauth/token`; client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e`; scopes `["user:profile"]`; callback path `/callback`; sign-in timeout `300` s; refresh leeway `60` s.
- Keychain item: service `"Claude Usage"`, account `"claude.ai"`. Never read `"Claude Code-credentials"`.
- Listener binds IPv4 loopback only, ephemeral port, one-shot; success page must not contain the code.
- User-facing strings (copy verbatim): `"Couldn't start the local sign-in listener"`, `"Sign-in was cancelled"`, `"Sign-in response didn't match — try again"`, `"Sign-in timed out"`, `"Sign-in failed (HTTP nnn)"`, `"Sign-in failed — couldn't reach Anthropic"`, `"Couldn't save the login to the keychain"`, `"Anthropic rejected the token — sign in again"`, `"Couldn't reach Anthropic"`, `"Keychain access denied — re-allow in prompt"`, `"Couldn't read credentials"`, `"Sign in with your Claude account to see usage"`, `"Finish signing in in your browser…"`.
- Run package tests with `swift test --package-path ClaudeUsageCore`; build the app with `xcodebuild -project "Claude Usage.xcodeproj" -scheme "Claude Usage" build`.
- Work on branch `app-owned-oauth-login`; commit after every task; end commit messages with the session's attribution lines.

---

### Task 1: OAuthConfiguration and PKCE

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/OAuthConfiguration.swift`
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/PKCE.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/PKCETests.swift`

**Interfaces:**
- Produces: `OAuthConfiguration` (`authorizeURL`, `tokenURL`, `clientID`, `scopes`, `callbackPath`, `signInTimeout`, `refreshLeeway`, `static let claude`, `func redirectURI(port: UInt16) -> String`); `PKCE` (`codeVerifier`, `codeChallenge`, `state`, `init()`, `init(verifierBytes:stateBytes:)`, `static func challenge(for:) -> String`).

- [ ] **Step 1: Create the branch**

```bash
git checkout -b app-owned-oauth-login
```

- [ ] **Step 2: Write the failing tests**

```swift
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
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --package-path ClaudeUsageCore --filter PKCETests`
Expected: compile error, `PKCE` / `OAuthConfiguration` not found.

- [ ] **Step 4: Implement**

`OAuthConfiguration.swift`:

```swift
import Foundation

/// Endpoints and constants for Claude's OAuth login. These are the same
/// public-client values Claude Code uses (read from its binary); there is
/// no client secret.
public struct OAuthConfiguration: Sendable {
    public let authorizeURL: URL
    public let tokenURL: URL
    public let clientID: String
    public let scopes: [String]
    public let callbackPath: String
    public let signInTimeout: TimeInterval
    public let refreshLeeway: TimeInterval

    public init(authorizeURL: URL, tokenURL: URL, clientID: String, scopes: [String],
                callbackPath: String, signInTimeout: TimeInterval, refreshLeeway: TimeInterval) {
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.scopes = scopes
        self.callbackPath = callbackPath
        self.signInTimeout = signInTimeout
        self.refreshLeeway = refreshLeeway
    }

    public static let claude = OAuthConfiguration(
        authorizeURL: URL(string: "https://claude.com/cai/oauth/authorize")!,
        tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        scopes: ["user:profile"],
        callbackPath: "/callback",
        signInTimeout: 300,
        refreshLeeway: 60)

    public func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)\(callbackPath)"
    }
}
```

`PKCE.swift`:

```swift
import Foundation
import CryptoKit

/// RFC 7636 code verifier/challenge pair plus an OAuth `state` nonce.
public struct PKCE: Equatable, Sendable {
    public let codeVerifier: String
    public let codeChallenge: String
    public let state: String

    public init() {
        self.init(verifierBytes: Self.randomBytes(32), stateBytes: Self.randomBytes(32))
    }

    public init(verifierBytes: [UInt8], stateBytes: [UInt8]) {
        codeVerifier = Self.base64URL(Data(verifierBytes))
        codeChallenge = Self.challenge(for: codeVerifier)
        state = Self.base64URL(Data(stateBytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --package-path ClaudeUsageCore --filter PKCETests`
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add ClaudeUsageCore
git commit -m "Add OAuth configuration constants and PKCE helper"
```

---

### Task 2: AuthorizationRequest

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/AuthorizationRequest.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/AuthorizationRequestTests.swift`

**Interfaces:**
- Consumes: `OAuthConfiguration`, `PKCE`.
- Produces: `enum AuthorizationRequest { static func url(config: OAuthConfiguration, pkce: PKCE, port: UInt16) -> URL }`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path ClaudeUsageCore --filter AuthorizationRequestTests`
Expected: compile error, `AuthorizationRequest` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Builds the browser URL that starts the login. Parameter set mirrors
/// Claude Code's own login exactly.
public enum AuthorizationRequest {
    public static func url(config: OAuthConfiguration, pkce: PKCE, port: UInt16) -> URL {
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI(port: port)),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components.url!
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path ClaudeUsageCore --filter AuthorizationRequestTests`
Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageCore
git commit -m "Add authorize URL builder"
```

---

### Task 3: CallbackRequestParser

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/CallbackRequestParser.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/CallbackRequestParserTests.swift`

**Interfaces:**
- Produces: `enum CallbackRequest { case success(code: String, state: String); case denied(error: String); case notCallback }`; `enum CallbackRequestParser { static func parse(requestLine: String, callbackPath: String) -> CallbackRequest }`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path ClaudeUsageCore --filter CallbackRequestParserTests`
Expected: compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum CallbackRequest: Equatable, Sendable {
    case success(code: String, state: String)
    case denied(error: String)
    case notCallback
}

/// Interprets the first line of the HTTP request the browser sends to the
/// loopback listener after the user approves (or rejects) the login.
public enum CallbackRequestParser {
    public static func parse(requestLine: String, callbackPath: String) -> CallbackRequest {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              components.path == callbackPath else {
            return .notCallback
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let error = value("error") { return .denied(error: error) }
        guard let code = value("code"), let state = value("state") else { return .notCallback }
        return .success(code: code, state: state)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path ClaudeUsageCore --filter CallbackRequestParserTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageCore
git commit -m "Add OAuth callback request parser"
```

---

### Task 4: SignInError and CallbackListener

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/SignInError.swift`
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/CallbackListener.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/CallbackListenerTests.swift`

**Interfaces:**
- Consumes: `CallbackRequestParser`.
- Produces: `enum TokenError: Error, Equatable, Sendable { invalidGrant, http(Int), network(String), decoding }` and `enum SignInError: Error, Equatable, Sendable { listenerFailed, denied(String), stateMismatch, timedOut, exchangeFailed(TokenError), storeFailed, cancelled }` (both in `SignInError.swift`; Task 5 uses `TokenError` as-is). `protocol CallbackListening: Sendable { func start(expectedState: String) async throws -> UInt16; func waitForCallback(timeout: TimeInterval) async throws -> String; func stop() }`; `final class CallbackListener: CallbackListening`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path ClaudeUsageCore --filter CallbackListenerTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`SignInError.swift`:

```swift
import Foundation

public enum TokenError: Error, Equatable, Sendable {
    /// The refresh token (or authorization code) was rejected outright.
    case invalidGrant
    case http(Int)
    case network(String)
    case decoding
}

public enum SignInError: Error, Equatable, Sendable {
    case listenerFailed
    /// The authorization server redirected back with `error=…`.
    case denied(String)
    case stateMismatch
    case timedOut
    case exchangeFailed(TokenError)
    case storeFailed
    case cancelled
}
```

`CallbackListener.swift`:

```swift
import Foundation
import Network

public protocol CallbackListening: Sendable {
    /// Binds the loopback port and returns it. `expectedState` is checked
    /// against the browser redirect.
    func start(expectedState: String) async throws -> UInt16
    /// Resolves with the authorization code, or throws a `SignInError`.
    func waitForCallback(timeout: TimeInterval) async throws -> String
    func stop()
}

/// One-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
/// All mutable state is confined to `queue`.
public final class CallbackListener: CallbackListening, @unchecked Sendable {
    private let callbackPath: String
    private let queue = DispatchQueue(label: "ee.pixelchain.Claude-Usage.callback-listener")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var expectedState = ""
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?

    public init(callbackPath: String = OAuthConfiguration.claude.callbackPath) {
        self.callbackPath = callbackPath
    }

    public func start(expectedState: String) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw SignInError.listenerFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.expectedState = expectedState
                self.listener = listener
                var resumed = false
                listener.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed, .cancelled:
                        resumed = true
                        continuation.resume(throwing: SignInError.listenerFailed)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
            }
        }
    }

    public func waitForCallback(timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.awaitResult() }
            group.addTask {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { throw SignInError.cancelled }
                throw SignInError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
            self.finish(.failure(SignInError.cancelled))
        }
    }

    // MARK: - Internals (all on `queue`)

    private func awaitResult() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(SignInError.cancelled)) }
        }
    }

    /// Delivers the outcome once: to a waiting continuation, or buffered
    /// for the next `waitForCallback`. Later calls are ignored.
    private func finish(_ outcome: Result<String, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: outcome)
        } else if result == nil {
            result = outcome
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let requestLine = text.components(separatedBy: .newlines).first ?? ""
            self.handle(requestLine: requestLine, on: connection)
        }
    }

    private func handle(requestLine: String, on connection: NWConnection) {
        switch CallbackRequestParser.parse(requestLine: requestLine, callbackPath: callbackPath) {
        case .notCallback:
            respond(connection, status: "404 Not Found", body: Self.page(title: "Not found", message: ""))
        case .denied(let error):
            respond(connection, status: "200 OK",
                    body: Self.page(title: "Sign-in cancelled", message: "You can close this tab and try again from the app."))
            finish(.failure(SignInError.denied(error)))
        case .success(let code, let state):
            guard state == expectedState else {
                respond(connection, status: "400 Bad Request",
                        body: Self.page(title: "Sign-in failed", message: "This response didn't match the sign-in attempt. Try again from the app."))
                finish(.failure(SignInError.stateMismatch))
                return
            }
            respond(connection, status: "200 OK",
                    body: Self.page(title: "Signed in to Claude Usage", message: "You can close this tab."))
            finish(.success(code))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>\
        <style>body{font-family:-apple-system,system-ui,sans-serif;margin:15vh auto;max-width:28em;text-align:center;color:#333}</style>\
        </head><body><h2>\(title)</h2><p>\(message)</p></body></html>
        """
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path ClaudeUsageCore --filter CallbackListenerTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageCore
git commit -m "Add loopback callback listener for the OAuth redirect"
```

---

### Task 5: TokenSet and OAuthTokenClient

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/TokenSet.swift`
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/OAuthTokenClient.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/OAuthTokenClientTests.swift`

**Interfaces:**
- Consumes: `OAuthConfiguration`, `TokenError`.
- Produces: `struct TokenSet: Codable, Equatable, Sendable { accessToken, refreshToken, expiresAt: Date, scopes: [String], accountEmail: String? }`; `typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`; `protocol TokenExchanging: Sendable { func exchange(code:codeVerifier:state:redirectURI:) async throws -> TokenSet; func refresh(refreshToken:) async throws -> TokenSet }`; `struct OAuthTokenClient: TokenExchanging` with `init(config: = .claude, transport: = urlSessionTransport, now: = Date.init)`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path ClaudeUsageCore --filter OAuthTokenClientTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`TokenSet.swift`:

```swift
import Foundation

/// The app's own OAuth grant. Stored JSON-encoded in the app's keychain item.
public struct TokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]
    public var accountEmail: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date,
                scopes: [String], accountEmail: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountEmail = accountEmail
    }
}
```

`OAuthTokenClient.swift`:

```swift
import Foundation

public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public protocol TokenExchanging: Sendable {
    func exchange(code: String, codeVerifier: String, state: String, redirectURI: String) async throws -> TokenSet
    func refresh(refreshToken: String) async throws -> TokenSet
}

/// Talks to the token endpoint. Bodies are JSON, exactly as Claude Code sends them.
public struct OAuthTokenClient: TokenExchanging {
    private let config: OAuthConfiguration
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    public static let urlSessionTransport: HTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TokenError.network("non-HTTP response") }
        return (data, http)
    }

    public init(config: OAuthConfiguration = .claude,
                transport: @escaping HTTPTransport = OAuthTokenClient.urlSessionTransport,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.transport = transport
        self.now = now
    }

    public func exchange(code: String, codeVerifier: String, state: String, redirectURI: String) async throws -> TokenSet {
        try await post([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": config.clientID,
            "code_verifier": codeVerifier,
            "state": state,
        ], previousRefreshToken: nil)
    }

    public func refresh(refreshToken: String) async throws -> TokenSet {
        try await post([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
            "scope": config.scopes.joined(separator: " "),
        ], previousRefreshToken: refreshToken)
    }

    private struct RawResponse: Decodable {
        struct Account: Decodable { let email_address: String? }
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
        let account: Account?
    }

    private struct RawError: Decodable { let error: String? }

    private func post(_ body: [String: String], previousRefreshToken: String?) async throws -> TokenSet {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as TokenError {
            throw error
        } catch {
            throw TokenError.network(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            break
        case 401 where previousRefreshToken != nil:
            throw TokenError.invalidGrant
        case 400, 401:
            if (try? JSONDecoder().decode(RawError.self, from: data))?.error == "invalid_grant" {
                throw TokenError.invalidGrant
            }
            throw TokenError.http(response.statusCode)
        default:
            throw TokenError.http(response.statusCode)
        }

        guard let raw = try? JSONDecoder().decode(RawResponse.self, from: data) else { throw TokenError.decoding }
        guard let refreshToken = raw.refresh_token ?? previousRefreshToken else { throw TokenError.decoding }
        return TokenSet(accessToken: raw.access_token,
                        refreshToken: refreshToken,
                        expiresAt: now().addingTimeInterval(raw.expires_in ?? 3600),
                        scopes: (raw.scope ?? "").split(separator: " ").map(String.init),
                        accountEmail: raw.account?.email_address)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path ClaudeUsageCore --filter OAuthTokenClientTests`
Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageCore
git commit -m "Add OAuth token client for code exchange and refresh"
```

---

### Task 6: KeychainAccessing, SystemKeychain writes, KeychainTokenStore

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/SystemKeychain.swift` (moves `KeychainError` + `SystemKeychain` out of `Credentials.swift`, adds write/delete)
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/KeychainTokenStore.swift`
- Modify: `ClaudeUsageCore/Sources/ClaudeUsageCore/Credentials.swift` (remove `KeychainError`, `KeychainReading`, `SystemKeychain`; keep the old `KeychainCredentialsStore` compiling by giving it a private one-method adapter — simpler: change its `keychain` property type to `KeychainAccessing` and call `data(service:account:)` with account `""`. It is deleted in Task 8 anyway.)
- Modify: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/CredentialsStoreTests.swift` (its `FakeKeychain` must conform to `KeychainAccessing`)
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/KeychainTokenStoreTests.swift`

**Interfaces:**
- Produces: `protocol KeychainAccessing: Sendable { func data(service:account:) throws -> Data; func set(_ data: Data, service:account:) throws; func delete(service:account:) throws }` (throws `KeychainError`); `protocol TokenStoring: Sendable { func load() throws -> TokenSet?; func save(_:) throws; func clear() throws }` (throws `CredentialsError`); `struct KeychainTokenStore: TokenStoring` with `static let service = "Claude Usage"`, `static let account = "claude.ai"`, `init(keychain: KeychainAccessing = SystemKeychain())`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ClaudeUsageCore

/// In-memory keychain keyed by service+account. Shared by token-store and
/// credentials-store tests.
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path ClaudeUsageCore --filter KeychainTokenStoreTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`SystemKeychain.swift`:

```swift
import Foundation
import Security

public enum KeychainError: Error, Equatable, Sendable {
    case itemNotFound
    case accessDenied
    case os(OSStatus)
}

public protocol KeychainAccessing: Sendable {
    func data(service: String, account: String) throws -> Data
    func set(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// Generic-password items in the login keychain. Items this app creates
/// carry an ACL that trusts the app, so reading them back never prompts.
public struct SystemKeychain: KeychainAccessing {
    public init() {}

    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func data(service: String, account: String) throws -> Data {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try Self.check(status)
        guard let data = result as? Data else { throw KeychainError.os(status) }
        return data
    }

    public func set(_ data: Data, service: String, account: String) throws {
        let query = query(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = service
            try Self.check(SecItemAdd(add as CFDictionary, nil))
        } else {
            try Self.check(status)
        }
    }

    public func delete(service: String, account: String) throws {
        try Self.check(SecItemDelete(query(service: service, account: account) as CFDictionary))
    }

    private static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw KeychainError.itemNotFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw KeychainError.accessDenied
        default: throw KeychainError.os(status)
        }
    }
}
```

`KeychainTokenStore.swift`:

```swift
import Foundation

public protocol TokenStoring: Sendable {
    func load() throws -> TokenSet?
    func save(_ tokens: TokenSet) throws
    func clear() throws
}

/// Persists the app's own `TokenSet` in an app-created keychain item.
public struct KeychainTokenStore: TokenStoring {
    public static let service = "Claude Usage"
    public static let account = "claude.ai"

    private let keychain: KeychainAccessing

    public init(keychain: KeychainAccessing = SystemKeychain()) {
        self.keychain = keychain
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public func load() throws -> TokenSet? {
        let data: Data
        do {
            data = try keychain.data(service: Self.service, account: Self.account)
        } catch KeychainError.itemNotFound {
            return nil
        } catch let error as KeychainError {
            throw Self.map(error)
        }
        guard let tokens = try? Self.decoder.decode(TokenSet.self, from: data) else {
            throw CredentialsError.malformed
        }
        return tokens
    }

    public func save(_ tokens: TokenSet) throws {
        let data = try Self.encoder.encode(tokens)
        do {
            try keychain.set(data, service: Self.service, account: Self.account)
        } catch let error as KeychainError {
            throw Self.map(error)
        }
    }

    public func clear() throws {
        do {
            try keychain.delete(service: Self.service, account: Self.account)
        } catch KeychainError.itemNotFound {
            return
        } catch let error as KeychainError {
            throw Self.map(error)
        }
    }

    static func map(_ error: KeychainError) -> CredentialsError {
        switch error {
        case .itemNotFound: return .notLoggedIn
        case .accessDenied: return .accessDenied
        case .os(let status): return .keychain(status)
        }
    }
}
```

`Credentials.swift`: delete `KeychainError`, `KeychainReading`, `SystemKeychain`. In `KeychainCredentialsStore` change `private let keychain: KeychainReading` to `KeychainAccessing` and the read to `keychain.data(service: Self.service, account: "")`. In `CredentialsStoreTests.swift` delete the local `FakeKeychain` and build the store with `FakeKeychain()` from the new test file, seeding `items["Claude Code-credentials|"]` or setting `failure`. (Both files are deleted in Task 8; keep the edit minimal.)

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path ClaudeUsageCore`
Expected: all tests pass, including the adapted `CredentialsStoreTests`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageCore
git commit -m "Add app-owned keychain token store and keychain write support"
```

---

### Task 7: SignInFlow

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/SignInFlow.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/SignInFlowTests.swift`

**Interfaces:**
- Consumes: `PKCE`, `AuthorizationRequest`, `CallbackListening`, `TokenExchanging`, `SignInError`.
- Produces: `struct SignInFlow: Sendable` with `init(config: = .claude, tokens: TokenExchanging, makeListener: @Sendable (String) -> CallbackListening = { CallbackListener(callbackPath: $0) }, makePKCE: @Sendable () -> PKCE = { PKCE() })` and `func run(openURL: @Sendable (URL) -> Void) async throws -> TokenSet`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path ClaudeUsageCore --filter SignInFlowTests`
Expected: compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One interactive login: PKCE → loopback listener → browser → code → token exchange.
public struct SignInFlow: Sendable {
    private let config: OAuthConfiguration
    private let tokens: TokenExchanging
    private let makeListener: @Sendable (String) -> CallbackListening
    private let makePKCE: @Sendable () -> PKCE

    public init(config: OAuthConfiguration = .claude,
                tokens: TokenExchanging,
                makeListener: @escaping @Sendable (String) -> CallbackListening = { CallbackListener(callbackPath: $0) },
                makePKCE: @escaping @Sendable () -> PKCE = { PKCE() }) {
        self.config = config
        self.tokens = tokens
        self.makeListener = makeListener
        self.makePKCE = makePKCE
    }

    public func run(openURL: @Sendable (URL) -> Void) async throws -> TokenSet {
        let pkce = makePKCE()
        let listener = makeListener(config.callbackPath)
        defer { listener.stop() }

        let port = try await listener.start(expectedState: pkce.state)
        openURL(AuthorizationRequest.url(config: config, pkce: pkce, port: port))
        let code: String
        do {
            code = try await listener.waitForCallback(timeout: config.signInTimeout)
        } catch is CancellationError {
            throw SignInError.cancelled
        }
        do {
            return try await tokens.exchange(code: code, codeVerifier: pkce.codeVerifier,
                                             state: pkce.state, redirectURI: config.redirectURI(port: port))
        } catch let error as TokenError {
            throw SignInError.exchangeFailed(error)
        } catch is CancellationError {
            throw SignInError.cancelled
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path ClaudeUsageCore --filter SignInFlowTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageCore
git commit -m "Add SignInFlow orchestrating the interactive OAuth login"
```

---

### Task 8: Protocol switch, view model rewrite, delete the old store

**Files:**
- Modify: `ClaudeUsageCore/Sources/ClaudeUsageCore/Credentials.swift` (rewrite: `Credentials`, `CredentialsError`, async `CredentialsProviding`, `SessionManaging`; delete `KeychainCredentialsStore`)
- Delete: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/CredentialsStoreTests.swift`
- Modify: `ClaudeUsageCore/Sources/ClaudeUsageCore/UsageViewModel.swift`
- Modify: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/UsageViewModelTests.swift`

Note: the app target (`Claude_UsageApp.swift`) stops compiling after this task until Task 10. Package tests stay green.

**Interfaces:**
- Produces:

```swift
public enum CredentialsError: Error, Equatable, Sendable {
    case notLoggedIn, refreshFailed, accessDenied, malformed, keychain(OSStatus)
}
public protocol CredentialsProviding: Sendable {
    func read(now: Date) async throws -> Credentials
    func invalidate() async
}
public protocol SessionManaging: CredentialsProviding {
    func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws
    func signOut() async
}
```

`UsageViewModel`: `Phase` adds `.signedOut`, `.signingIn`; `@Published signInError: String?`; `init(credentials: SessionManaging, fetcher: UsageFetching, openURL: @escaping @Sendable (URL) -> Void, now: = Date.init)`; `refresh()`, `signIn() async`, `cancelSignIn()`, `signOut() async`; `static func message(for: CredentialsError) -> String`; `static func message(for: SignInError) -> String?`.

- [ ] **Step 1: Rewrite the view model tests**

Replace `UsageViewModelTests.swift` entirely:

```swift
import XCTest
@testable import ClaudeUsageCore

@MainActor
final class UsageViewModelTests: XCTestCase {
    final class FakeSession: SessionManaging, @unchecked Sendable {
        var readResults: [Result<Credentials, CredentialsError>]
        var signInResult: Result<Void, SignInError> = .success(())
        var readCount = 0, invalidateCount = 0, signOutCount = 0
        var openedURLs: [URL] = []

        init(_ results: [Result<Credentials, CredentialsError>]) { readResults = results }

        func read(now: Date) async throws -> Credentials {
            readCount += 1
            let result = readResults.count > 1 ? readResults.removeFirst() : readResults[0]
            return try result.get()
        }
        func invalidate() async { invalidateCount += 1 }
        func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws {
            let url = URL(string: "https://claude.com/cai/oauth/authorize?state=x")!
            openURL(url)
            openedURLs.append(url)
            await Task.yield() // let the view model's `.signingIn` phase be observed
            try signInResult.get()
        }
        func signOut() async { signOutCount += 1 }
    }

    final class FakeFetcher: UsageFetching, @unchecked Sendable {
        var results: [Result<UsageSnapshot, UsageError>]
        var calls = 0
        init(_ results: [Result<UsageSnapshot, UsageError>]) { self.results = results }
        func fetch(accessToken: String) async throws -> UsageSnapshot {
            calls += 1
            let result = results.count > 1 ? results.removeFirst() : results[0]
            return try result.get()
        }
    }

    final class URLBox: @unchecked Sendable { var urls: [URL] = [] }

    static let now = Date(timeIntervalSince1970: 1_781_179_200)
    static let validCredentials = Credentials(accessToken: "sk-test", expiresAt: now.addingTimeInterval(3600))
    static let snapshot = UsageSnapshot(windows: [
        LimitWindow(id: "five_hour", label: "Session (5h)", utilization: 62, resetsAt: now.addingTimeInterval(8040)),
        LimitWindow(id: "seven_day", label: "Week (all models)", utilization: 31, resetsAt: now.addingTimeInterval(100_000)),
    ])

    private var session = FakeSession([.success(UsageViewModelTests.validCredentials)])
    private var fetcher = FakeFetcher([.success(UsageViewModelTests.snapshot)])
    private let opened = URLBox()

    private func makeViewModel(
        credentials: [Result<Credentials, CredentialsError>] = [.success(UsageViewModelTests.validCredentials)],
        fetch: [Result<UsageSnapshot, UsageError>] = [.success(UsageViewModelTests.snapshot)]
    ) -> UsageViewModel {
        session = FakeSession(credentials)
        fetcher = FakeFetcher(fetch)
        return UsageViewModel(credentials: session, fetcher: fetcher,
                              openURL: { [opened] in opened.urls.append($0) }, now: { Self.now })
    }

    func testSuccessfulRefresh() async {
        let viewModel = makeViewModel()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
        XCTAssertEqual(viewModel.fetchedAt, Self.now)
    }

    func testMostConstrainedPicksHighestUtilization() async {
        let viewModel = makeViewModel()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.mostConstrained?.id, "five_hour")
    }

    func testMostConstrainedIsNilWithoutData() {
        XCTAssertNil(makeViewModel().mostConstrained)
    }

    func testNotLoggedInIsSignedOut() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertNil(viewModel.snapshot)
        XCTAssertEqual(fetcher.calls, 0)
    }

    func testRefreshFailedKeepsSnapshotAndDegrades() async {
        let viewModel = makeViewModel(credentials: [.success(Self.validCredentials), .failure(.refreshFailed)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Couldn't reach Anthropic"))
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
    }

    func testAccessDenied() async {
        let viewModel = makeViewModel(credentials: [.failure(.accessDenied)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Keychain access denied — re-allow in prompt"))
    }

    func testUnauthorizedRetriesOnceAfterInvalidate() async {
        let viewModel = makeViewModel(fetch: [.failure(.unauthorized), .success(Self.snapshot)])
        await viewModel.refresh()
        XCTAssertEqual(session.invalidateCount, 1)
        XCTAssertEqual(session.readCount, 2)
        XCTAssertEqual(fetcher.calls, 2)
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
    }

    func testSecondUnauthorizedSignsOut() async {
        let viewModel = makeViewModel(fetch: [.failure(.unauthorized), .failure(.unauthorized)])
        await viewModel.refresh()
        XCTAssertEqual(session.invalidateCount, 1)
        XCTAssertEqual(session.signOutCount, 1)
        XCTAssertEqual(fetcher.calls, 2)
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertNil(viewModel.snapshot)
        XCTAssertEqual(viewModel.signInError, "Anthropic rejected the token — sign in again")
    }

    func testNetworkErrorKeepsLastSnapshot() async {
        let viewModel = makeViewModel(fetch: [.success(Self.snapshot), .failure(.http(503))])
        await viewModel.refresh()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Couldn't reach Anthropic"))
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
    }

    func testRecoversFromDegradedOnNextRefresh() async {
        let viewModel = makeViewModel(fetch: [.failure(.http(503)), .success(Self.snapshot)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Couldn't reach Anthropic"))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
    }

    func testSignInSuccessOpensBrowserThenLoads() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn), .success(Self.validCredentials)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .signedOut)
        await viewModel.signIn()
        XCTAssertEqual(opened.urls.first?.host, "claude.com")
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
        XCTAssertNil(viewModel.signInError)
    }

    func testSignInFailureShowsMessage() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn)])
        session.signInResult = .failure(.timedOut)
        await viewModel.signIn()
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertEqual(viewModel.signInError, "Sign-in timed out")
    }

    func testSignInCancelledHasNoMessage() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn)])
        session.signInResult = .failure(.cancelled)
        await viewModel.signIn()
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertNil(viewModel.signInError)
    }

    func testRefreshIsNoOpWhileSigningIn() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn)])
        await viewModel.refresh()
        let signInTask = Task { await viewModel.signIn() }
        await Task.yield() // signIn sets `.signingIn` before its first suspension
        XCTAssertEqual(viewModel.phase, .signingIn)
        await viewModel.refresh()
        XCTAssertEqual(session.readCount, 1) // only the initial refresh read
        await signInTask.value
    }

    func testSignOutClearsEverything() async {
        let viewModel = makeViewModel()
        await viewModel.refresh()
        await viewModel.signOut()
        XCTAssertEqual(session.signOutCount, 1)
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertNil(viewModel.snapshot)
        XCTAssertNil(viewModel.fetchedAt)
    }

    func testSignInMessages() {
        XCTAssertEqual(UsageViewModel.message(for: .listenerFailed), "Couldn't start the local sign-in listener")
        XCTAssertEqual(UsageViewModel.message(for: .denied("access_denied")), "Sign-in was cancelled")
        XCTAssertEqual(UsageViewModel.message(for: .stateMismatch), "Sign-in response didn't match — try again")
        XCTAssertEqual(UsageViewModel.message(for: .timedOut), "Sign-in timed out")
        XCTAssertEqual(UsageViewModel.message(for: .exchangeFailed(.http(502))), "Sign-in failed (HTTP 502)")
        XCTAssertEqual(UsageViewModel.message(for: .exchangeFailed(.network("x"))), "Sign-in failed — couldn't reach Anthropic")
        XCTAssertEqual(UsageViewModel.message(for: .exchangeFailed(.decoding)), "Sign-in failed")
        XCTAssertEqual(UsageViewModel.message(for: .storeFailed), "Couldn't save the login to the keychain")
        XCTAssertNil(UsageViewModel.message(for: .cancelled))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path ClaudeUsageCore --filter UsageViewModelTests`
Expected: compile errors (`SessionManaging`, `.signedOut`, `signIn` missing).

- [ ] **Step 3: Rewrite `Credentials.swift`**

```swift
import Foundation

public struct Credentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date

    public init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public enum CredentialsError: Error, Equatable, Sendable {
    /// No stored login — the UI should offer Sign in.
    case notLoggedIn
    /// Refresh hit a network/HTTP problem; stored tokens are untouched.
    case refreshFailed
    case accessDenied
    case malformed
    case keychain(OSStatus)
}

/// Hands out a usable access token, refreshing behind the scenes.
public protocol CredentialsProviding: Sendable {
    func read(now: Date) async throws -> Credentials
    /// Treat the current access token as expired so the next `read` refreshes.
    func invalidate() async
}

public protocol SessionManaging: CredentialsProviding {
    func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws
    func signOut() async
}
```

Delete `CredentialsStoreTests.swift`.

- [ ] **Step 4: Rewrite `UsageViewModel.swift`**

```swift
import Foundation
import Combine

@MainActor
public final class UsageViewModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case degraded(String)
        case signedOut
        case signingIn
    }

    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var fetchedAt: Date?
    @Published public private(set) var phase: Phase = .loading
    @Published public private(set) var signInError: String?

    public static let refreshInterval: TimeInterval = 300

    private let credentials: SessionManaging
    private var fetcher: UsageFetching
    private let openURL: @Sendable (URL) -> Void
    private let now: () -> Date
    private var autoRefreshTask: Task<Void, Never>?
    private var signInTask: Task<Void, Error>?

    public init(credentials: SessionManaging,
                fetcher: UsageFetching,
                openURL: @escaping @Sendable (URL) -> Void,
                now: @escaping () -> Date = Date.init) {
        self.credentials = credentials
        self.fetcher = fetcher
        self.openURL = openURL
        self.now = now
    }

    deinit {
        autoRefreshTask?.cancel()
        signInTask?.cancel()
    }

    /// The limit closest to its cap — what the menu bar shows.
    public var mostConstrained: LimitWindow? {
        snapshot?.windows.max(by: { $0.utilization < $1.utilization })
    }

    /// Refresh now and every `refreshInterval` seconds thereafter. Idempotent.
    public func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    public func refresh() async {
        guard phase != .signingIn else { return }
        let token: String
        do {
            token = try await credentials.read(now: now()).accessToken
        } catch CredentialsError.notLoggedIn {
            snapshot = nil
            phase = .signedOut
            return
        } catch let error as CredentialsError {
            phase = .degraded(Self.message(for: error))
            return
        } catch {
            phase = .degraded("Couldn't read credentials")
            return
        }
        do {
            try await fetchAndStore(token)
        } catch UsageError.unauthorized {
            await retryAfterUnauthorized()
        } catch {
            phase = .degraded("Couldn't reach Anthropic")
        }
    }

    /// Runs the browser login. Safe to call while one is in progress (joins it).
    public func signIn() async {
        if let signInTask {
            _ = try? await signInTask.value
            return
        }
        phase = .signingIn
        signInError = nil
        let task = Task { [credentials, openURL] in
            try await credentials.signIn(openURL: openURL)
        }
        signInTask = task
        defer { signInTask = nil }
        do {
            try await task.value
            phase = .loading
            await refresh()
        } catch let error as SignInError {
            phase = .signedOut
            signInError = Self.message(for: error)
        } catch is CancellationError {
            phase = .signedOut
        } catch {
            phase = .signedOut
            signInError = "Sign-in failed"
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
    }

    public func signOut() async {
        signInTask?.cancel()
        await credentials.signOut()
        snapshot = nil
        fetchedAt = nil
        signInError = nil
        phase = .signedOut
    }

    private func fetchAndStore(_ token: String) async throws {
        snapshot = try await fetcher.fetch(accessToken: token)
        fetchedAt = now()
        phase = .loaded
    }

    /// One forced refresh + retry. A second 401 means the grant itself is
    /// bad, so the stored login is dropped and the user is asked to sign in.
    private func retryAfterUnauthorized() async {
        await credentials.invalidate()
        do {
            let token = try await credentials.read(now: now()).accessToken
            try await fetchAndStore(token)
        } catch UsageError.unauthorized {
            await credentials.signOut()
            snapshot = nil
            phase = .signedOut
            signInError = "Anthropic rejected the token — sign in again"
        } catch CredentialsError.notLoggedIn {
            snapshot = nil
            phase = .signedOut
        } catch let error as CredentialsError {
            phase = .degraded(Self.message(for: error))
        } catch {
            phase = .degraded("Couldn't reach Anthropic")
        }
    }

    static func message(for error: CredentialsError) -> String {
        switch error {
        case .notLoggedIn: return "Not signed in"
        case .refreshFailed: return "Couldn't reach Anthropic"
        case .accessDenied: return "Keychain access denied — re-allow in prompt"
        case .malformed, .keychain: return "Couldn't read credentials"
        }
    }

    static func message(for error: SignInError) -> String? {
        switch error {
        case .listenerFailed: return "Couldn't start the local sign-in listener"
        case .denied: return "Sign-in was cancelled"
        case .stateMismatch: return "Sign-in response didn't match — try again"
        case .timedOut: return "Sign-in timed out"
        case .exchangeFailed(.http(let status)): return "Sign-in failed (HTTP \(status))"
        case .exchangeFailed(.network): return "Sign-in failed — couldn't reach Anthropic"
        case .exchangeFailed: return "Sign-in failed"
        case .storeFailed: return "Couldn't save the login to the keychain"
        case .cancelled: return nil
        }
    }

    func setFetcherForTesting(_ fetcher: UsageFetching) {
        self.fetcher = fetcher
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --package-path ClaudeUsageCore`
Expected: all package tests pass (`CredentialsStoreTests` gone, 16 view model tests green).

- [ ] **Step 6: Commit**

```bash
git add -A ClaudeUsageCore
git commit -m "Switch view model to an async session protocol with sign-in/out; drop Claude Code keychain reader"
```

---

### Task 9: OAuthCredentialsStore

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/OAuth/OAuthCredentialsStore.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/OAuthCredentialsStoreTests.swift`

**Interfaces:**
- Consumes: `TokenStoring`, `TokenExchanging`, `SignInFlow`, `SessionManaging`, `FakeExchanger` (from `SignInFlowTests.swift`), `FakeKeychain` (from `KeychainTokenStoreTests.swift`).
- Produces: `public actor OAuthCredentialsStore: SessionManaging` with `init(store: TokenStoring, tokens: TokenExchanging, config: OAuthConfiguration = .claude, flow: SignInFlow? = nil)`.

- [ ] **Step 1: Write the failing tests**

```swift
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
        XCTAssertEqual(try await store.read(now: Self.now).accessToken, "at-new")
    }

    func testInvalidateForcesRefresh() async throws {
        let store = try makeStore(seed: Self.valid)
        _ = try await store.read(now: Self.now)
        await store.invalidate()
        XCTAssertEqual(try await store.read(now: Self.now).accessToken, "at-new")
        XCTAssertEqual(exchanger.refreshes, ["rt-1"])
    }

    func testSignInSavesTokens() async throws {
        let store = try makeStore(seed: nil)
        exchanger.exchangeResult = .success(Self.valid)
        try await store.signIn { _ in }
        XCTAssertEqual(try await store.read(now: Self.now).accessToken, "at-1")
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path ClaudeUsageCore --filter OAuthCredentialsStoreTests`
Expected: compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Owns the app's OAuth grant: loads it once from the keychain, hands out
/// the access token while it is fresh, refreshes it when it is not, and
/// runs the interactive sign-in. Serialised by the actor; concurrent reads
/// during a refresh share one network call.
public actor OAuthCredentialsStore: SessionManaging {
    private let store: TokenStoring
    private let tokens: TokenExchanging
    private let flow: SignInFlow
    private let leeway: TimeInterval
    private var cached: TokenSet?
    private var loaded = false
    private var refreshTask: Task<TokenSet, Error>?

    public init(store: TokenStoring,
                tokens: TokenExchanging,
                config: OAuthConfiguration = .claude,
                flow: SignInFlow? = nil) {
        self.store = store
        self.tokens = tokens
        self.flow = flow ?? SignInFlow(config: config, tokens: tokens)
        self.leeway = config.refreshLeeway
    }

    public func read(now: Date) async throws -> Credentials {
        guard let current = try loadIfNeeded() else { throw CredentialsError.notLoggedIn }
        if current.expiresAt > now.addingTimeInterval(leeway) {
            return Credentials(accessToken: current.accessToken, expiresAt: current.expiresAt)
        }
        let fresh = try await refresh(current)
        return Credentials(accessToken: fresh.accessToken, expiresAt: fresh.expiresAt)
    }

    public func invalidate() {
        guard var current = cached else { return }
        current.expiresAt = .distantPast
        cached = current
    }

    public func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws {
        let fresh = try await flow.run(openURL: openURL)
        do {
            try store.save(fresh)
        } catch {
            throw SignInError.storeFailed
        }
        cached = fresh
        loaded = true
    }

    public func signOut() {
        try? store.clear()
        cached = nil
        loaded = true
    }

    // MARK: - Internals

    private func loadIfNeeded() throws -> TokenSet? {
        if !loaded {
            cached = try store.load()
            loaded = true
        }
        return cached
    }

    private func refresh(_ current: TokenSet) async throws -> TokenSet {
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let task = Task { try await self.performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ current: TokenSet) async throws -> TokenSet {
        let fresh: TokenSet
        do {
            fresh = try await tokens.refresh(refreshToken: current.refreshToken)
        } catch TokenError.invalidGrant {
            try? store.clear()
            cached = nil
            throw CredentialsError.notLoggedIn
        } catch {
            throw CredentialsError.refreshFailed
        }
        try store.save(fresh)
        cached = fresh
        return fresh
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path ClaudeUsageCore`
Expected: all package tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageCore
git commit -m "Add OAuthCredentialsStore actor: cached tokens, shared refresh, sign-in/out"
```

---

### Task 10: App wiring and popover UI

**Files:**
- Modify: `Claude Usage/Claude_UsageApp.swift`
- Modify: `Claude Usage/UsagePopoverView.swift`

**Interfaces:**
- Consumes: `OAuthCredentialsStore`, `KeychainTokenStore`, `OAuthTokenClient`, `UsageViewModel` (`phase`, `signInError`, `signIn()`, `cancelSignIn()`, `signOut()`).

- [ ] **Step 1: Wire the app**

`Claude_UsageApp.swift`:

```swift
import SwiftUI
import ClaudeUsageCore

@main
struct Claude_UsageApp: App {
    @StateObject private var viewModel = UsageViewModel(
        credentials: OAuthCredentialsStore(store: KeychainTokenStore(), tokens: OAuthTokenClient()),
        fetcher: UsageClient(),
        openURL: { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    )

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
                .onAppear { viewModel.startAutoRefresh() }
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 2: Update the popover**

In `UsagePopoverView.swift` replace `content` and `footer` with:

```swift
    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .signedOut:
            signedOutContent
        case .signingIn:
            signingInContent
        default:
            usageContent
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        if let snapshot = viewModel.snapshot, !snapshot.windows.isEmpty {
            ForEach(snapshot.windows) { window in
                LimitRowView(window: window)
            }
        } else if viewModel.phase == .loading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            Text("No limit data reported")
                .foregroundStyle(.secondary)
        }
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in with your Claude account to see usage")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Sign in") {
                Task { await viewModel.signIn() }
            }
            if let error = viewModel.signInError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var signingInContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…")
                    .font(.callout)
            }
            Button("Cancel") {
                viewModel.cancelSignIn()
            }
        }
    }

    private var isSignedIn: Bool {
        switch viewModel.phase {
        case .signedOut, .signingIn: return false
        default: return true
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let fetchedAt = viewModel.fetchedAt {
                    Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSignedIn {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
                }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(enabled: newValue)
                }
            HStack {
                if isSignedIn {
                    Button("Sign out") {
                        Task { await viewModel.signOut() }
                    }
                    .font(.caption)
                }
                Spacer()
                Button("Quit Claude Usage") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
            }
        }
    }
```

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project "Claude Usage.xcodeproj" -scheme "Claude Usage" build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "Claude Usage"
git commit -m "Wire app-owned OAuth login into the app and add sign-in/out UI"
```

---

### Task 11: README and live verification (scope check)

**Files:**
- Modify: `README.md`
- Throwaway: `<scratchpad>/scopecheck/` Swift package (not committed)

- [ ] **Step 1: Update README**

Replace the Requirements, Install step 3, and "How it works / privacy" sections:

```markdown
## Requirements

- macOS 14 (Sonoma) or later
- A Claude subscription (Pro/Max). Claude Code does not need to be installed.

## Install

1. Download the latest `ClaudeUsage-*.pkg` from
   [Releases](https://github.com/djeux/claude-usage-widget/releases).
2. The package isn't notarized yet, so macOS will warn on open:
   right-click the `.pkg` → Open → Open (or allow it under
   System Settings → Privacy & Security → "Open Anyway").
3. Open the menu bar item and click **Sign in**. Approve in the browser;
   the app finishes signing in on its own. No keychain prompts.

## How it works / privacy

- Signs in with your Claude account through the same OAuth login Claude
  Code uses, asking only for the `user:profile` scope — the app cannot
  run inference with its token.
- Stores its own tokens in a keychain item it creates (`Claude Usage`),
  so macOS never asks you to allow access. It never reads Claude Code's
  keychain item.
- Talks only to `claude.com` / `platform.claude.com` (sign-in and token
  refresh) and `https://api.anthropic.com/api/oauth/usage` (the same
  endpoint Claude Code's `/usage` uses), every 5 minutes.
- No analytics, no third-party servers, no dependencies.
- If Anthropic rejects the token, the app shows **Sign in** again; if the
  network is down it dims the last data and retries.
```

- [ ] **Step 2: Live scope check (throwaway)**

Create `<scratchpad>/scopecheck/Package.swift` depending on the core package by path, and `main.swift` that runs `SignInFlow` with `openURL` printing the URL, then calls `UsageClient().fetch(accessToken:)` and prints the HTTP outcome. Open the printed URL in the browser (Chrome tools, or the user), approve, and read the script's output. Expected: `exchange OK`, scopes `["user:profile"]`, `usage fetch OK` with window count > 0. If the usage call returns 401/403, record the failure in the spec's Open items and widen `OAuthConfiguration.claude.scopes` to the smallest working set, re-running the check.

- [ ] **Step 3: Run the full suite and app build once more**

Run: `swift test --package-path ClaudeUsageCore && xcodebuild -project "Claude Usage.xcodeproj" -scheme "Claude Usage" build 2>&1 | tail -3`
Expected: all tests pass, `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add README.md docs
git commit -m "Document the app-owned sign-in; record live scope check result"
```

---

### Task 12: Push and open the PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin app-owned-oauth-login
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "Replace Claude Code keychain read with app-owned OAuth login" --body "$(cat <<'EOF'
## Summary
- Sign in through Claude's OAuth (same public client as Claude Code, `user:profile` scope only) instead of reading `Claude Code-credentials` from the keychain
- App-owned keychain item + silent refresh: zero keychain prompts, no dependency on Claude Code being installed or recently used
- Popover gains Sign in / Cancel / Sign out; a rejected token after refresh returns to Sign in

Spec: docs/superpowers/specs/2026-09-14-app-owned-oauth-login-design.md

## Test plan
- [ ] `swift test --package-path ClaudeUsageCore` green
- [ ] App builds
- [ ] Live: Sign in → approve in browser → popover shows limits; relaunch keeps session; Sign out returns to Sign in

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_014cYcv8EWVZBtLRhsE32fQ5
EOF
)"
```
