#if os(macOS)
import CoreFoundation
import Foundation

/// The folder that holds everything Chat Computer keeps: the virtual Mac, API keys, chats, tasks and the control
/// socket: `~/.chatcomputer`, or a folder chosen in setup. The app, `chatcomputer` and `cc-harness` all find it here.
///
/// Resolved in order: `CC_DATA_DIR` (development), the folder saved in the app's preferences, then the default.
public enum DataDirectory {
    /// The app's preferences domain; read by every process, so not `UserDefaults.standard`.
    public static let preferencesDomain = "app.chatcomputer.ChatComputer"
    public static let preferenceKey = "DataDirectory"
    public static let environmentKey = "CC_DATA_DIR"

    public static var defaultURL: URL { home.appendingPathComponent(".chatcomputer", isDirectory: true) }

    public static var current: URL {
        resolve(environment: ProcessInfo.processInfo.environment[environmentKey], saved: savedPath)
    }

    /// Set by the environment, so the folder can't be chosen in setup.
    public static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment[environmentKey] ?? "").isEmpty
    }

    static func resolve(environment: String?, saved: String?) -> URL {
        if let path = environment, !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true) }
        if let path = saved, !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return defaultURL
    }

    public static var savedPath: String? {
        CFPreferencesCopyAppValue(preferenceKey as CFString, preferencesDomain as CFString) as? String
    }

    /// Records the folder for every process; setup records it before installing.
    public static func save(_ url: URL) {
        CFPreferencesSetAppValue(preferenceKey as CFString, url.standardizedFileURL.path as CFString, preferencesDomain as CFString)
        CFPreferencesAppSynchronize(preferencesDomain as CFString)
    }

    /// Creates the folder, readable only by this user (it holds the API keys and the guest password).
    public static func create(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The files that make a folder Chat Computer data, rather than a folder that happens to exist.
    static let markers = ["ChatComputer.vm", "credentials.json", "session.json", "Tasks"]

    public static func hasData(_ url: URL) -> Bool {
        markers.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// The data folder for a folder the user picked: the folder itself when it is empty, missing or already Chat
    /// Computer data, otherwise a `ChatComputer` folder inside it, so the app's files don't mix with theirs.
    public static func folder(forChoice url: URL) -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if contents.allSatisfy({ $0.hasPrefix(".") }) || hasData(url) { return url }
        return url.appendingPathComponent("ChatComputer", isDirectory: true)
    }

    public enum Problem: Error, LocalizedError, Equatable {
        case syncedFolder
        case notAPFS(String)
        case notWritable
        case pathTooLong

        public var errorDescription: String? {
            switch self {
            case .syncedFolder: "This folder syncs to the cloud. The virtual Mac's disk is tens of gigabytes and changes all the time; choose a folder that doesn't sync."
            case .notAPFS(let format): "This disk is formatted as \(format). Snapshots need APFS; choose a folder on an APFS disk."
            case .notWritable: "Chat Computer can't write to this folder."
            case .pathTooLong: "This folder's path is too long for the connection coding agents use; choose one with a shorter path."
            }
        }
    }

    /// Whether the virtual Mac can live here: on APFS (snapshots are clones), outside synced folders, writable, and
    /// with a path short enough for the control socket.
    public static func check(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        if Array((path + "/control.sock").utf8).count >= 104 { throw Problem.pathTooLong }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        for synced in ["Library/Mobile Documents", "Library/CloudStorage"].map({ home.appendingPathComponent($0).path })
            where resolved == synced || resolved.hasPrefix(synced + "/") {
            throw Problem.syncedFolder
        }
        var existing = URL(fileURLWithPath: resolved, isDirectory: true)
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        if (try? existing.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { throw Problem.syncedFolder }
        var info = statfs()
        if statfs(existing.path, &info) == 0 {
            let format = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if format != "apfs" { throw Problem.notAPFS(format) }
        }
        if !FileManager.default.isWritableFile(atPath: existing.path) { throw Problem.notWritable }
    }

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
}
#endif
