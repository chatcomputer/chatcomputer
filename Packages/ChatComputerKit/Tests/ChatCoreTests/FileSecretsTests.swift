import Foundation
import Testing
@testable import ChatCore

@Suite struct FileSecretsTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileSecretsTests-\(UUID().uuidString)")

    @Test func fileIsPrivateAndRoundTrips() throws {
        let store = FileSecretStore(url: directory.appendingPathComponent("secrets.json"))
        #expect(try store.read("a") == nil)
        try store.write("one", for: "a")
        try store.write("two", for: "b")
        try store.delete("b")
        #expect(try store.read("a") == "one")
        #expect(try store.read("b") == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Only the file itself is left in the folder: no temporary files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["secrets.json"])
    }

    @Test func machineAndModelSecretsGoToTheirOwnFiles() throws {
        let store = HostSecretStore(machineFile: directory.appendingPathComponent("vm/secrets.json"),
                                    credentialsFile: directory.appendingPathComponent("credentials.json"))
        try store.write("token", for: "vm.1234.pairingToken")
        try store.write("sk-test", for: "model.deepseek.apiKey")
        #expect(try store.machine.read("vm.1234.pairingToken") == "token")
        #expect(try store.machine.read("model.deepseek.apiKey") == nil)
        #expect(try store.credentials.read("model.deepseek.apiKey") == "sk-test")
    }
}
