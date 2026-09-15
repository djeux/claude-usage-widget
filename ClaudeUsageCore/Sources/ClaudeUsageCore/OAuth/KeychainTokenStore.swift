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
