#if os(macOS)
import BridgeProtocol
import Foundation

/// Bounded local evidence for setup failures before any model task exists.
/// Callers pass fixed stage names, never screen text, passwords or tool inputs.
public struct PermissionJournal: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("permission-events.jsonl")
    }

    public struct Entry: Codable, Sendable {
        public var date: Date
        public var stage: String
        public var hostVersion: String
        public var appVersion: String
        public var guest: PermissionDiagnostics?
    }

    public func append(stage: String, appVersion: String, guest: PermissionDiagnostics? = nil) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(Entry(date: Date(), stage: stage,
                                            hostVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                            appVersion: appVersion, guest: guest))
        line.append(0x0a)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var data = (try? Data(contentsOf: url)) ?? Data()
        // Trim complete lines only; the last failure remains readable after restart.
        if data.count + line.count > 256 * 1024 {
            data = Data(data.suffix(128 * 1024))
            if let newline = data.firstIndex(of: 0x0a) { data.removeSubrange(...newline) }
        }
        data.append(line)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif
