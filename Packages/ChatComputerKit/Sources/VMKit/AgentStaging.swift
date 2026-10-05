#if os(macOS)
import Foundation

/// Puts a guest agent in the bootstrap share for the guest to install, in a way the guest sees.
///
/// A macOS guest (27.0.1) keeps stale entries in a shared folder when a name is pointed at a new file or folder:
/// a folder deleted and recreated under the same name, or a file replaced by renaming a new one over it, reads as
/// missing in the guest, even seconds later. A file deleted first and then created under the same name, and any
/// name the guest has never looked up, are seen at once. So each update gets a folder with a new name (listed in
/// `next-agent`, newest first by name), and the fixed path that older agents read is refreshed file by file:
/// delete, then create, keeping its folders.
public enum AgentStaging {
    public static let agentName = "ChatComputerAgent.app"

    /// Stages `agent` and returns the update's own folder, to delete once the guest has installed it.
    @discardableResult
    public static func stage(_ agent: URL, in bootstrap: URL) throws -> URL {
        let fm = FileManager.default
        let updates = bootstrap.appendingPathComponent("updates", isDirectory: true)
        try fm.createDirectory(at: updates, withIntermediateDirectories: true)
        // Earlier updates' folders are never reused, so they can go.
        for old in (try? fm.contentsOfDirectory(at: updates, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: old)
        }
        // Sortable and never repeated: newest last by name.
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        let folder = updates.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.copyItem(at: agent, to: folder.appendingPathComponent(agentName))

        try refreshInPlace(agent, to: bootstrap.appendingPathComponent(agentName))

        let pointer = bootstrap.appendingPathComponent("next-agent")
        try? fm.removeItem(at: pointer)
        try Data("updates/\(name)/\(agentName)".utf8).write(to: pointer)
        return folder
    }

    /// Makes `destination` a copy of `source`: each file is deleted, then created again (never renamed over),
    /// folders are kept, and entries `source` does not have are removed.
    public static func refreshInPlace(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let wanted = Set((try? fm.contentsOfDirectory(atPath: source.path)) ?? [])
        for existing in (try? fm.contentsOfDirectory(atPath: destination.path)) ?? [] where !wanted.contains(existing) {
            try fm.removeItem(at: destination.appendingPathComponent(existing))
        }
        for name in wanted {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &isFolder)
            let values = try from.resourceValues(forKeys: [.isSymbolicLinkKey])
            if isFolder.boolValue, values.isSymbolicLink != true {
                var destinationIsFolder: ObjCBool = false
                if fm.fileExists(atPath: to.path, isDirectory: &destinationIsFolder), !destinationIsFolder.boolValue {
                    try fm.removeItem(at: to)
                }
                try refreshInPlace(from, to: to)
            } else {
                if fm.fileExists(atPath: to.path) || (try? fm.destinationOfSymbolicLink(atPath: to.path)) != nil {
                    try fm.removeItem(at: to)
                }
                try fm.copyItem(at: from, to: to)
            }
        }
    }
}
#endif
