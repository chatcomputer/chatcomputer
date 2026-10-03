#if os(macOS)
import AppKit
import BridgeProtocol
import ChatCore
import Foundation
import GuestBridge
import HostControl
import VMKit

/// `cc-harness vm share-test`: changes the shared folders of a running VM and watches the guest agent.
///
/// After each change it polls the agent's health for a while and captures the guest screen from the
/// host (which needs no agent), so a guest that stops answering can still be seen.
@MainActor
enum ShareTest {
    static func run() async throws {
        let bundle = VMProbe.bundle
        let secrets = bundle.secretStore()
        let controller = try VirtualMachineController(bundle: bundle)
        let vmID = controller.spec.id
        guard let token = try secrets.read(SecretAccount.pairingToken(vmID: vmID)) else { throw ProbeError("no pairing token in secrets.json") }
        let bridge = BridgeServer(vmID: vmID, pairingToken: token)
        controller.onSocketDeviceReady = { bridge.attach(to: $0) }
        await controller.start()
        guard controller.state == .running, let machine = controller.virtualMachine else { throw ProbeError("start failed: \(controller.state)") }
        let (view, _) = VMProbe.showWindow(machine, spec: controller.spec)
        let display = HostDisplay(view: view, guestSize: CGSize(width: controller.spec.displayWidth / 2, height: controller.spec.displayHeight / 2))

        func health(_ seconds: TimeInterval = 5) async -> String {
            let started = Date()
            guard await bridge.isConnected else { return "not connected" }
            let result = try? await bridge.send(CommandEnvelope(vmID: vmID, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                deadline: Date().addingTimeInterval(seconds), command: .health))
            let took = String(format: "%.2fs", Date().timeIntervalSince(started))
            if case .health(let report)? = result { return "ready=\(report.isDesktopReady) shares=\(report.sharedFoldersMounted) in \(took)" }
            return "no answer (\(result.map { "\($0)" } ?? "timeout")) after \(took)"
        }
        func watch(_ label: String, seconds: Int = 20) async {
            VMProbe.log("\(label):")
            var last = ""
            for second in 0..<seconds {
                let now = await health()
                if now != last { VMProbe.log("  t+\(second)s \(now)") }
                last = now
                try? await Task.sleep(for: .seconds(1))
            }
            if let image = display.capture() {
                let url = bundle.url.appendingPathComponent("share-test-\(label.replacingOccurrences(of: " ", with: "-")).png")
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                VMProbe.log("  screen → \(url.path)")
            }
        }

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, !(await health()).hasPrefix("ready=true") { try await Task.sleep(for: .seconds(1)) }
        await watch("before", seconds: 3)

        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/cc-share-test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for existing in controller.shares where existing.path == folder.resolvingSymlinksInPath().path { try controller.removeShare(existing.id) }
        await watch("after clearing old shares", seconds: 10)
        let share = try controller.addShare(folder)
        await watch("after adding a share")
        try controller.removeShare(share.id)
        await watch("after removing it")
        controller.setBootstrapAttached(true)
        await watch("after attaching bootstrap")
        controller.setBootstrapAttached(false)
        await watch("after detaching bootstrap")
        try await VMProbe.shutdown(controller, bridge: bridge)
    }
}
#endif
