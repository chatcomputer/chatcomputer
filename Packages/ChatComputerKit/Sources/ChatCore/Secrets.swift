import Foundation

/// Secrets the host keeps: model API keys, and per VM the guest password and pairing token.
/// The app keeps them in 0600 files (`HostSecretStore`).
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


/// Test double; never used by the shipping app.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(_ account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    public func delete(_ account: String) throws { lock.withLock { values[account] = nil } }
}
