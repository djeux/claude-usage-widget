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
