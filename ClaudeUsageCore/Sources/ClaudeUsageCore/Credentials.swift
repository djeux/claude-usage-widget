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
    case notLoggedIn
    case accessDenied
    case expired
    case malformed
    case keychain(OSStatus)
}

public protocol CredentialsProviding: Sendable {
    func read(now: Date) throws -> Credentials
}

public struct KeychainCredentialsStore: CredentialsProviding {
    public static let service = "Claude Code-credentials"

    private let keychain: KeychainAccessing

    public init(keychain: KeychainAccessing = SystemKeychain()) {
        self.keychain = keychain
    }

    private struct RawCredentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double // milliseconds since epoch
        }
        let claudeAiOauth: OAuth
    }

    public func read(now: Date) throws -> Credentials {
        let data: Data
        do {
            data = try keychain.data(service: Self.service, account: "")
        } catch let error as KeychainError {
            switch error {
            case .itemNotFound: throw CredentialsError.notLoggedIn
            case .accessDenied: throw CredentialsError.accessDenied
            case .os(let status): throw CredentialsError.keychain(status)
            }
        }
        guard let raw = try? JSONDecoder().decode(RawCredentials.self, from: data) else {
            throw CredentialsError.malformed
        }
        let expiresAt = Date(timeIntervalSince1970: raw.claudeAiOauth.expiresAt / 1000)
        guard expiresAt > now else { throw CredentialsError.expired }
        return Credentials(accessToken: raw.claudeAiOauth.accessToken, expiresAt: expiresAt)
    }
}
