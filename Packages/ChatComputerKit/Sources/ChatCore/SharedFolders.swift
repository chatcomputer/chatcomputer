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

    public func inbox(for jobID: UUID) -> URL { inbox.appendingPathComponent(jobID.uuidString, isDirectory: true) }
    public func outbox(for jobID: UUID) -> URL { outbox.appendingPathComponent(jobID.uuidString, isDirectory: true) }

    /// Paths the guest agent and the model should use for a job.
    public static let guestMountPoint = "/Volumes/My Shared Files"
    public static func guestOutboxPath(for jobID: UUID) -> String { "\(guestMountPoint)/outbox/\(jobID.uuidString)" }
    public static func guestInboxPath(for jobID: UUID) -> String { "\(guestMountPoint)/inbox/\(jobID.uuidString)" }

    public func prepare(jobID: UUID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inbox(for: jobID), withIntermediateDirectories: true)
        try fm.createDirectory(at: outbox(for: jobID), withIntermediateDirectories: true)
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
