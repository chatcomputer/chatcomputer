#if os(macOS)
import Foundation
import Testing
@testable import VMKit

@Suite struct UserSharesTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UserSharesTests-\(UUID().uuidString)").resolvingSymlinksInPath()
    var home: URL { root.appendingPathComponent("home") }
    var appData: URL { home.appendingPathComponent("Library/Application Support/ChatComputer") }

    init() throws {
        for folder in ["home/Projects/site", "home/Projects/Other/site", "home/.ssh", "home/Library/Application Support/ChatComputer/ChatComputer.vm", "home/Documents"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data().write(to: home.appendingPathComponent("Documents/file.txt"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Projects/keys"), withDestinationURL: home.appendingPathComponent(".ssh"))
    }

    private func check(_ path: String, existing: [UserShare] = []) throws -> (path: String, name: String) {
        try SharePolicy.check(home.appendingPathComponent(path), existing: existing, home: home.path, appData: appData.path, systemFolders: [])
    }

    @Test func ordinaryFoldersAreShared() throws {
        let checked = try check("Projects/site")
        #expect(checked.name == "site")
        #expect(checked.path == home.appendingPathComponent("Projects/site").path)
    }

    @Test func sensitiveFoldersAreRefused() {
        for path in ["", ".ssh", "Library", "Library/Application Support/ChatComputer", "Library/Application Support/ChatComputer/ChatComputer.vm"] {
            #expect(throws: ShareError.self, "\(path)") { try check(path) }
        }
        // A symlink to a refused folder is refused too.
        #expect(throws: ShareError.self) { try check("Projects/keys") }
        // Files and missing folders are not folders.
        #expect(throws: ShareError.self) { try check("Documents/file.txt") }
        #expect(throws: ShareError.self) { try check("Missing") }
        // A parent of the app's data would expose the virtual Mac's own disk.
        #expect(throws: ShareError.self) {
            try SharePolicy.check(home.appendingPathComponent("Library/Application Support"), existing: [], home: root.path + "/elsewhere",
                                  appData: appData.path, systemFolders: [])
        }
    }

    @Test func systemFoldersAreRefused() {
        for path in ["/", "/Users", "/System/Library", "/usr/bin", "/private/etc"] {
            #expect(throws: ShareError.self, "\(path)") {
                try SharePolicy.check(URL(fileURLWithPath: path), existing: [], appData: appData.path)
            }
        }
    }

    @Test func namesStayUniqueAndAvoidBuiltInFolders() throws {
        let first = try check("Projects/site")
        let existing = [UserShare(name: first.name, path: first.path, readOnly: true)]
        #expect(throws: ShareError.alreadyShared("site")) { try check("Projects/site", existing: existing) }
        #expect(try check("Projects/Other/site", existing: existing).name == "site 2")

        try FileManager.default.createDirectory(at: home.appendingPathComponent("Outbox"), withIntermediateDirectories: true)
        #expect(try check("Outbox").name == "Outbox 2")
    }

    @Test func sharesPersistInTheBundle() throws {
        let bundle = VMBundle(url: root.appendingPathComponent("Test.vm"))
        try bundle.create()
        #expect(bundle.loadShares().isEmpty)
        let share = UserShare(name: "site", path: "/tmp/site", readOnly: false)
        try bundle.saveShares([share])
        #expect(bundle.loadShares() == [share])
    }
}
#endif
