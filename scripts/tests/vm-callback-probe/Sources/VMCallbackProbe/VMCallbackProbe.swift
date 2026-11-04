import Foundation
import Virtualization
import VMKit
import Darwin

@main
struct CallbackProbe {
    @MainActor static func main() async throws {
        // A real, stopped Linux EFI VM object suffices as a foreign delegate
        // sender. Neither it nor the controller's temporary Mac is booted.
        let config = VZVirtualMachineConfiguration()
        let efiURL = FileManager.default.temporaryDirectory.appendingPathComponent("cc-callback-efi-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: efiURL) }
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
        config.bootLoader = bootLoader
        config.cpuCount = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        config.memorySize = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        try config.validate()
        let foreign = VZVirtualMachine(configuration: config)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cc-callback-probe-\(UUID()).vm")
        let bundle = VMBundle(url: url)
        try bundle.create()
        defer { try? FileManager.default.removeItem(at: url) }
        try bundle.save(VMSpec(macAddress: "02:00:00:00:00:01"))
        let controller = try VirtualMachineController(bundle: bundle)
        guard controller.state == .stopped, controller.virtualMachine == nil else {
            fatalError("The temporary controller was not initially stopped")
        }
        controller.virtualMachine(foreign, didStopWithError: NSError(domain: "ForeignCallbackProbe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Error from an unowned stopped VM"]))
        // Also allow delayed delivery here so this probe detects the former Task-based implementation.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(100))
        let rejectedError = controller.state == .stopped && controller.virtualMachine == nil
        controller.guestDidStop(foreign)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(100))
        let passed = rejectedError && controller.state == .stopped && controller.virtualMachine == nil
        let result: [String: Any] = ["passed": passed, "actualControllerState": String(describing: controller.state),
            "nativeVMStarted": false, "foreignStoppedVMObject": true,
            "scope": "Reject stop callbacks from a VM the controller does not own; not proof of the original restore failure's cause"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        try FileManager.default.removeItem(at: url)
        if !passed { exit(1) }
    }
}
