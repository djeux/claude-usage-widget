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
