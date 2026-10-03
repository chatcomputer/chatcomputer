#if os(macOS)
import Foundation

/// A folder on this Mac shared into the virtual Mac, as `/Volumes/My Shared Files/<name>`.
public struct UserShare: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The folder's name in the guest; unique, never one of the built-in folders.
    public var name: String
    /// Absolute path on the host, symlinks resolved.
    public var path: String
    public var readOnly: Bool

    public init(id: UUID = UUID(), name: String, path: String, readOnly: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.readOnly = readOnly
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    public var guestPath: String { "/Volumes/My Shared Files/\(name)" }
}

public enum ShareError: Error, Equatable, LocalizedError {
    case notAFolder(String)
    case sensitive(String)
    case alreadyShared(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notAFolder(let path): "\(path) is not a folder this app can read."
        case .sensitive(let reason): "This folder can't be shared: \(reason)"
        case .alreadyShared(let name): "This folder is already shared as “\(name)”."
        case .notFound: "That shared folder no longer exists."
        }
    }
}

/// Which folders may be shared into a guest that an AI model operates, and what the guest calls them.
public enum SharePolicy {
    /// Names the app uses itself in the guest's shared folder.
    public static let reservedNames: Set<String> = ["inbox", "outbox", "bootstrap"]

    /// Checks a folder the user wants to share and returns its resolved path and guest name.
    ///
    /// Refused: the disk root and system folders, `/Users`, the whole home folder, `~/Library`, hidden folders
    /// in the home folder (`~/.ssh`, `~/.aws`, `~/.config`, …), and the app's own data. Symlinks are resolved
    /// first, so a link can't smuggle any of these in.
    public static let systemFolders = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/etc", "/var", "/dev", "/opt", "/cores"]

    public static func check(_ url: URL, existing: [UserShare], home: String = NSHomeDirectory(),
                             appData: String, systemFolders: [String] = systemFolders) throws -> (path: String, name: String) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            throw ShareError.notAFolder(path)
        }
        let home = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        let appData = URL(fileURLWithPath: appData).resolvingSymlinksInPath().standardizedFileURL.path
        func isInside(_ child: String, _ parent: String) -> Bool { child == parent || child.hasPrefix(parent + "/") }

        if path == "/" || path == "/Users" || path == "/Volumes" || systemFolders.contains(where: { isInside(path, $0) }) {
            throw ShareError.sensitive("it is part of macOS itself.")
        }
        if path == home { throw ShareError.sensitive("share a folder inside your home folder instead of all of it.") }
        if isInside(path, home + "/Library") { throw ShareError.sensitive("~/Library holds app data, passwords and settings.") }
        if isInside(path, home) {
            let first = path.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? ""
            if first.hasPrefix(".") { throw ShareError.sensitive("hidden folders in your home folder often hold keys and credentials.") }
        }
        if isInside(path, appData) || isInside(appData, path) {
            throw ShareError.sensitive("it contains Chat Computer's own data, including the virtual Mac itself.")
        }
        if let duplicate = existing.first(where: { $0.path == path }) { throw ShareError.alreadyShared(duplicate.name) }

        let base = URL(fileURLWithPath: path).lastPathComponent
        let taken = Set(existing.map { $0.name.lowercased() }).union(reservedNames)
        var name = base
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        return (path, name)
    }
}

extension VMBundle {
    /// The user's shared folders. Host configuration, so snapshots don't include it.
    public var sharesURL: URL { url.appendingPathComponent("shares.json") }

    public func loadShares() -> [UserShare] {
        guard let data = try? Data(contentsOf: sharesURL) else { return [] }
        return (try? JSONDecoder().decode([UserShare].self, from: data)) ?? []
    }

    public func saveShares(_ shares: [UserShare]) throws {
        try VMBundle.encode(shares).write(to: sharesURL, options: .atomic)
    }
}
#endif
