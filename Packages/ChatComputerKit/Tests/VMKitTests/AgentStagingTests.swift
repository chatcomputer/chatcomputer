#if os(macOS)
import Foundation
import Testing
@testable import VMKit

@Suite struct AgentStagingTests {
    private func fakeAgent(_ root: URL, version: String) throws -> URL {
        let app = root.appendingPathComponent("src-\(version)/ChatComputerAgent.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data(version.utf8).write(to: app.appendingPathComponent("Contents/MacOS/ChatComputerAgent"))
        return app
    }

    private func inode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int) ?? -1
    }

    /// Each update gets a new folder named in `next-agent`; the fixed path is updated without being recreated.
    @Test func stagesInANewFolderAndUpdatesTheFixedPathInPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        let bootstrap = root.appendingPathComponent("bootstrap")
        let first = try AgentStaging.stage(try fakeAgent(root, version: "1"), in: bootstrap)
        let fixed = bootstrap.appendingPathComponent("ChatComputerAgent.app")
        let fixedInode = try inode(fixed)
        let pointer1 = try String(contentsOf: bootstrap.appendingPathComponent("next-agent"), encoding: .utf8)

        let second = try AgentStaging.stage(try fakeAgent(root, version: "2"), in: bootstrap)
        let pointer2 = try String(contentsOf: bootstrap.appendingPathComponent("next-agent"), encoding: .utf8)
        #expect(pointer1 != pointer2)
        #expect(first != second)
        #expect(!FileManager.default.fileExists(atPath: first.path))   // old update folders are cleared
        #expect(try String(contentsOf: bootstrap.appendingPathComponent(pointer2).appendingPathComponent("Contents/MacOS/ChatComputerAgent"), encoding: .utf8) == "2")
        #expect(try inode(fixed) == fixedInode)   // the folder is kept
        #expect(try String(contentsOf: fixed.appendingPathComponent("Contents/MacOS/ChatComputerAgent"), encoding: .utf8) == "2")
    }
}
#endif
