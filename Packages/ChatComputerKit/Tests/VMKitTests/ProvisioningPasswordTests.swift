#if os(macOS)
import Foundation
import ChatCore
import Testing
@testable import VMKit

@Suite struct ProvisioningPasswordTests {
    @Test @MainActor func retryKeepsThePasswordOfTheExistingAccount() throws {
        let store = InMemorySecretStore()
        let spec = VMSpec(macAddress: "02:00:00:00:00:01")
        let provisioner = GuestProvisioner(bundle: VMBundle(url: URL(fileURLWithPath: "/tmp/unused-provisioning-test")), secrets: store)
        let first = try provisioner.firstBootOptions(spec: spec, password: "fixture-original")
        let second = try provisioner.firstBootOptions(spec: spec)
        #expect(first.password == "fixture-original")
        #expect(second.password == first.password)
    }

    @Test @MainActor func retryCannotSilentlyReplaceTheSavedPassword() throws {
        let store = InMemorySecretStore()
        let spec = VMSpec(macAddress: "02:00:00:00:00:01")
        try store.write("fixture-original", for: SecretAccount.guestPassword(vmID: spec.id))
        let provisioner = GuestProvisioner(bundle: VMBundle(url: URL(fileURLWithPath: "/tmp/unused-provisioning-test")), secrets: store)
        #expect(throws: VMError.self) { try provisioner.firstBootOptions(spec: spec, password: "fixture-replacement") }
        #expect(try store.read(SecretAccount.guestPassword(vmID: spec.id)) == "fixture-original")
    }
}
#endif
