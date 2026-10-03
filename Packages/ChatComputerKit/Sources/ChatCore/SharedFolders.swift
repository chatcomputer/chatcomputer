import Foundation

/// Host-side layout of the per-task folders shared into the guest over virtio-fs.
///
/// `inbox` is shared read-only, `outbox` read-write. The guest sees them under
/// `/Volumes/My Shared Files/` (the macOS automount tag).
public struct SharedFolders: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }

    public func inbox(for task: TaskRecord) -> URL { inbox.appendingPathComponent(Self.folderName(for: task), isDirectory: true) }
    public func outbox(for task: TaskRecord) -> URL { outbox.appendingPathComponent(Self.folderName(for: task), isDirectory: true) }

    /// Paths the guest agent and the model should use for a task.
    public static let guestMountPoint = "/Volumes/My Shared Files"
    public static func guestOutboxPath(for task: TaskRecord) -> String { "\(guestMountPoint)/outbox/\(folderName(for: task))" }
    public static func guestInboxPath(for task: TaskRecord) -> String { "\(guestMountPoint)/inbox/\(folderName(for: task))" }

    /// "2026-10-02_14-05_3f2a": sorts by time and stays readable. ASCII without spaces, because the agent types
    /// these paths into save dialogs as real key presses.
    public static func folderName(for task: TaskRecord) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: task.createdAt)
        let stamp = String(format: "%04d-%02d-%02d_%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        return "\(stamp)_\(task.id.uuidString.prefix(4).lowercased())"
    }

    public func prepare(task: TaskRecord) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inbox(for: task), withIntermediateDirectories: true)
        try fm.createDirectory(at: outbox(for: task), withIntermediateDirectories: true)
    }

    /// Copies files into a task's inbox before it starts and returns the names the guest sees.
    public func attach(_ files: [URL], to task: TaskRecord) throws -> [String] {
        let folder = inbox(for: task)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        for file in files {
            let name = Self.uniqueName(file.lastPathComponent, in: folder)
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
            names.append(name)
        }
        return names
    }

    /// Bytes and number of files under a folder (symlinks are not followed).
    public static func usage(of folder: URL) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) ?? .init() {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return (bytes, files)
    }

    /// Removes items directly inside `folder` last modified before `date`, except the names in `keeping`
    /// (the running task's folder). Returns how many were removed.
    @discardableResult
    public static func removeItems(in folder: URL, olderThan date: Date, keeping: Set<String> = []) throws -> Int {
        var removed = 0
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items where !keeping.contains(item.lastPathComponent) {
            // A folder counts as recent if anything inside it changed recently.
            if newestModification(item) < date {
                try FileManager.default.removeItem(at: item)
                removed += 1
            }
        }
        return removed
    }

    static func newestModification(_ url: URL) -> Date {
        var newest = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        for case let child as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) ?? .init() {
            if let date = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date > newest { newest = date }
        }
        return newest
    }

    /// "report.pdf", then "report 2.pdf", … for a name that's taken.
    static func uniqueName(_ name: String, in folder: URL) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        return candidate
    }
}

/// Validates a file the guest produced before it leaves the outbox (proposal §07).
///
/// The guest controls the outbox contents, so everything here is treated as untrusted:
/// names come from the model, files may be symlinks pointing anywhere on the host.
public struct ExportValidator: Sendable {
    public var maxBytes: Int
    public var allowedExtensions: Set<String>?

    public init(maxBytes: Int = 200 * 1024 * 1024, allowedExtensions: Set<String>? = nil) {
        self.maxBytes = maxBytes
        self.allowedExtensions = allowedExtensions
    }

    public enum Rejection: Error, Equatable {
        case invalidName
        case escapesOutbox
        case symbolicLink
        case notRegularFile
        case missing
        case tooLarge(Int)
        case disallowedType(String)
    }

    /// Resolves `relativePath` inside `outbox` and returns the validated file URL and size.
    public func validate(relativePath: String, in outbox: URL) throws -> (url: URL, bytes: Int) {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              !components.contains(where: { $0 == ".." || $0 == "." }),
              !relativePath.contains("\0") else {
            throw Rejection.invalidName
        }

        let base = outbox.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = base
        let fm = FileManager.default
        // Walk component by component so a symlinked parent directory is caught too.
        for component in components {
            candidate.appendPathComponent(String(component))
            guard let attributes = try? fm.attributesOfItem(atPath: candidate.path) else {
                throw Rejection.missing
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw Rejection.symbolicLink
            }
        }

        guard candidate.standardizedFileURL.path.hasPrefix(base.path + "/") else {
            throw Rejection.escapesOutbox
        }
        let attributes = try fm.attributesOfItem(atPath: candidate.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Rejection.notRegularFile
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw Rejection.tooLarge(size) }
        if let allowed = allowedExtensions {
            let ext = candidate.pathExtension.lowercased()
            guard allowed.contains(ext) else { throw Rejection.disallowedType(ext) }
        }
        return (candidate, size)
    }
}
