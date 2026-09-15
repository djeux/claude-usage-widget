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
