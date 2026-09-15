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
