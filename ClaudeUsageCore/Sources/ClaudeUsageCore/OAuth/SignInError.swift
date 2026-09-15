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
