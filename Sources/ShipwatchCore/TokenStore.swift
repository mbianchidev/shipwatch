import Foundation
import Security

public protocol TokenStore: Sendable {
    func load() throws -> OAuthToken?
    func save(_ token: OAuthToken) throws
    func delete() throws
}

public enum KeychainError: Error, LocalizedError, Equatable {
    case status(OSStatus, String)

    public var errorDescription: String? {
        switch self {
        case .status(let status, let action):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain could not \(action) the GitHub token: \(reason)"
        }
    }
}

/// Stores the token JSON as a generic password in the login keychain.
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    public init(service: String = "dev.mbianchi.shipwatch", account: String = "github-app-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> OAuthToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status, "read")
        }
        return try JSON.decoder.decode(OAuthToken.self, from: data)
    }

    public func save(_ token: OAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update, "update") }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Shipwatch GitHub token"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status, "save") }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status, "delete")
        }
    }
}

/// Keeps tokens in memory only. Used by tests and the snapshot renderer.
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: OAuthToken?

    public init(_ token: OAuthToken? = nil) {
        self.token = token
    }

    public func load() throws -> OAuthToken? {
        lock.withLock { token }
    }

    public func save(_ token: OAuthToken) throws {
        lock.withLock { self.token = token }
    }

    public func delete() throws {
        lock.withLock { token = nil }
    }
}
