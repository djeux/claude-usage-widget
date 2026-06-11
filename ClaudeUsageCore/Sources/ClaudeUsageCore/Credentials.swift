import Foundation
import Security

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

public enum KeychainError: Error, Equatable, Sendable {
    case itemNotFound
    case accessDenied
    case os(OSStatus)
}

public protocol KeychainReading: Sendable {
    func data(service: String) throws -> Data
}

/// Real keychain access via SecItemCopyMatching. The first read of another
/// app's item triggers the macOS keychain prompt — the user should click
/// "Always Allow".
public struct SystemKeychain: KeychainReading {
    public init() {}

    public func data(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.os(status) }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.os(status)
        }
    }
}

public protocol CredentialsProviding: Sendable {
    func read(now: Date) throws -> Credentials
}

public struct KeychainCredentialsStore: CredentialsProviding {
    public static let service = "Claude Code-credentials"

    private let keychain: KeychainReading

    public init(keychain: KeychainReading = SystemKeychain()) {
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
            data = try keychain.data(service: Self.service)
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
