import Foundation
#if canImport(Security)
import Security
#endif

/// Secrets the host keeps: the model API key and per-VM guest account passwords.
///
/// Per the proposal (§03) there is no plaintext fallback: if the Keychain fails,
/// the caller surfaces the error to the user.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ value: String, for account: String) throws
    func delete(_ account: String) throws
}

public enum SecretAccount {
    public static let anthropicAPIKey = "model.anthropic.apiKey"
    public static func guestPassword(vmID: UUID) -> String { "vm.\(vmID.uuidString).guestPassword" }
    /// One-time secret the guest agent presents in its hello; proves it runs in the VM we provisioned.
    public static func pairingToken(vmID: UUID) -> String { "vm.\(vmID.uuidString).pairingToken" }
}

public struct SecretStoreError: Error, Equatable {
    public let status: Int32
}

#if canImport(Security)
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "app.chatcomputer") {
        self.service = service
    }

    public func read(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecretStoreError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }

    /// The login (file-based) keychain. The data-protection keychain needs a keychain-access-groups
    /// entitlement backed by a provisioning profile; a Developer ID app without one gets
    /// errSecMissingEntitlement (-34018) on every call (observed on macOS 27). Login-keychain items
    /// are bound to the app's code signature, which stays stable across Developer ID releases.
    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#endif

/// Test double; never used by the shipping app.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(_ account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    public func delete(_ account: String) throws { lock.withLock { values[account] = nil } }
}
