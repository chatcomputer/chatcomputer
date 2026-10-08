#if os(macOS)
import AppKit
import BridgeProtocol

/// Opens an app or a file the way a double click in Finder does, then waits until it is in front.
enum AppOpener {
    static let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                          "/Applications/Utilities", "/System/Library/CoreServices/Applications"]

    static func open(app: String?, path: String?) async throws {
        let appURL = try app.map(locate)
        var fileURL: URL?
        if let path, !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw BridgeError(.invalidCommand, "There is no file at \(url.path).")
            }
            fileURL = url
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened: NSRunningApplication
        do {
            switch (appURL, fileURL) {
            case (let appURL?, let fileURL?):
                opened = try await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration)
            case (nil, let fileURL?):
                guard let handler = NSWorkspace.shared.urlForApplication(toOpen: fileURL) else {
                    throw BridgeError(.invalidCommand, "No app opens \(fileURL.lastPathComponent).")
                }
                opened = try await NSWorkspace.shared.open([fileURL], withApplicationAt: handler, configuration: configuration)
            case (let appURL?, nil):
                opened = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            case (nil, nil):
                throw BridgeError(.invalidCommand, "Give open_app an app, a file, or both.")
            }
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError(.driverFailure, "Could not open it: \(error.localizedDescription)")
        }
        // Up to 8 s for the app to come forward with a window; a cold start of Safari or Numbers takes a few.
        for _ in 0..<40 {
            if opened.isFinishedLaunching, NSWorkspace.shared.frontmostApplication?.processIdentifier == opened.processIdentifier {
                try await Task.sleep(for: .milliseconds(500))
                return
            }
            opened.activate()
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// "TextEdit", "textedit", "TextEdit.app" or a bundle identifier.
    static func locate(_ name: String) throws -> URL {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if wanted.contains("."), !wanted.lowercased().hasSuffix(".app"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: wanted) {
            return url
        }
        let file = (wanted.lowercased().hasSuffix(".app") ? wanted : wanted + ".app").lowercased()
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            if let match = entries.first(where: { $0.lowercased() == file }) {
                return URL(fileURLWithPath: folder).appendingPathComponent(match)
            }
        }
        throw BridgeError(.invalidCommand, "No app named \(wanted) in Applications.")
    }
}
#endif
