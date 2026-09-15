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
