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
