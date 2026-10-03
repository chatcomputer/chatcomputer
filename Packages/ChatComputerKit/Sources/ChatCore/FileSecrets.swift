import Foundation

/// Secrets in a JSON file readable only by this user (0600). Writes replace the file in one rename,
/// and the file never exists with wider permissions.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func read(_ account: String) throws -> String? {
        lock.withLock { load()[account] }
    }

    public func write(_ value: String, for account: String) throws {
        try lock.withLock {
            var values = load()
            values[account] = value
            try save(values)
        }
    }

    public func delete(_ account: String) throws {
        try lock.withLock {
            var values = load()
            guard values.removeValue(forKey: account) != nil else { return }
            try save(values)
        }
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save(_ values: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Where the app keeps its secrets: each VM's guest password and pairing token in a file inside its
/// bundle (whoever can read the bundle can read the whole guest disk anyway), and model API keys in a
/// file in Application Support, as Claude Code and Codex keep their credentials.
///
/// Up to 0.1.1 these lived in the login Keychain, whose items are bound to the signature of the build
/// that wrote them, so every other build had to ask. A secret missing from the files is looked up there
/// once (`legacy`) and moved over.
public struct HostSecretStore: SecretStore {
    public let machine: FileSecretStore
    public let credentials: FileSecretStore
    private let legacy: (any SecretStore)?

    public init(machineFile: URL, credentialsFile: URL, legacy: (any SecretStore)? = nil) {
        machine = FileSecretStore(url: machineFile)
        credentials = FileSecretStore(url: credentialsFile)
        self.legacy = legacy
    }

    private func store(for account: String) -> FileSecretStore {
        account.hasPrefix("vm.") ? machine : credentials
    }

    public func read(_ account: String) throws -> String? {
        let store = store(for: account)
        if let value = try store.read(account) { return value }
        guard let legacy, let value = try legacy.read(account) else { return nil }
        try store.write(value, for: account)
        try? legacy.delete(account)
        return value
    }

    public func write(_ value: String, for account: String) throws {
        try store(for: account).write(value, for: account)
    }

    public func delete(_ account: String) throws {
        try store(for: account).delete(account)
        try? legacy?.delete(account)
    }
}
