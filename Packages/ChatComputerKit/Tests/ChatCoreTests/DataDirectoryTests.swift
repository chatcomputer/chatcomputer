import Foundation
import Testing
@testable import ChatCore

@Suite struct DataDirectoryTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DataDirectoryTests-\(UUID().uuidString)")

    @Test func environmentThenSavedThenDefault() {
        #expect(DataDirectory.resolve(environment: "/tmp/cc", saved: "/Volumes/Big/cc").path == "/tmp/cc")
        #expect(DataDirectory.resolve(environment: "", saved: "/Volumes/Big/cc").path == "/Volumes/Big/cc")
        #expect(DataDirectory.resolve(environment: nil, saved: nil) == DataDirectory.defaultURL)
        #expect(DataDirectory.defaultURL.path == NSHomeDirectory() + "/.chatcomputer")
    }

    @Test func aFolderWithOtherFilesGetsItsOwnSubfolder() throws {
        let fileManager = FileManager.default
        let empty = directory.appendingPathComponent("empty")
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        #expect(DataDirectory.folder(forChoice: empty) == empty)
        #expect(DataDirectory.folder(forChoice: directory.appendingPathComponent("missing")).lastPathComponent == "missing")

        let existing = directory.appendingPathComponent("existing")
        try fileManager.createDirectory(at: existing.appendingPathComponent("ChatComputer.vm"), withIntermediateDirectories: true)
        try Data().write(to: existing.appendingPathComponent("notes.txt"))
        #expect(DataDirectory.folder(forChoice: existing) == existing)

        let busy = directory.appendingPathComponent("busy")
        try fileManager.createDirectory(at: busy, withIntermediateDirectories: true)
        try Data().write(to: busy.appendingPathComponent("notes.txt"))
        #expect(DataDirectory.folder(forChoice: busy).path == busy.appendingPathComponent("ChatComputer").path)
    }

    @Test func refusesSyncedFoldersAndLongPaths() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #expect(throws: DataDirectory.Problem.syncedFolder) {
            try DataDirectory.check(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/cc"))
        }
        #expect(throws: DataDirectory.Problem.syncedFolder) {
            try DataDirectory.check(home.appendingPathComponent("Library/CloudStorage/Dropbox/cc"))
        }
        #expect(throws: DataDirectory.Problem.pathTooLong) {
            try DataDirectory.check(directory.appendingPathComponent(String(repeating: "a", count: 100)))
        }
        // $TMPDIR's own path is already too long for a socket; /tmp is short.
        try DataDirectory.check(URL(fileURLWithPath: "/tmp/DataDirectoryTests-\(UUID().uuidString.prefix(8))"))
    }

    @Test func createdFolderIsPrivate() throws {
        let folder = directory.appendingPathComponent("data")
        try DataDirectory.create(folder)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}
