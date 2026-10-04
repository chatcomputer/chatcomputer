#if os(macOS)
import Foundation
import Testing
@testable import VMKit

@Suite struct DownloadTests {
    actor Fractions { var values: [Double] = []; func add(_ v: Double) { values.append(v) } }

    /// The restore image download reports progress and leaves the file where it was asked to.
    @Test func downloadsWithProgress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source.bin")
        try Data(repeating: 7, count: 3 << 20).write(to: source)
        let target = folder.appendingPathComponent("RestoreImage.ipsw")
        let fractions = Fractions()
        try await MacOSInstaller.download(source, to: target) { fraction in Task { await fractions.add(fraction) } }
        #expect(FileManager.default.contents(atPath: target.path)?.count == 3 << 20)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fractions.values.last == 1)
    }

    @Test func aMissingSourceThrows() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        await #expect(throws: (any Error).self) {
            try await MacOSInstaller.download(folder.appendingPathComponent("nope"), to: folder.appendingPathComponent("x")) { _ in }
        }
    }
}
#endif
