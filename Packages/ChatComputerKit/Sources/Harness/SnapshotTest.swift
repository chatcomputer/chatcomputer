#if os(macOS)
import BridgeProtocol
import ChatCore
import CoreGraphics
import Foundation
import GuestBridge
import ImageIO
import VMKit

/// `cc-harness vm snapshot-test`: snapshots on a real, paired VM.
///
/// 1. Live snapshot of the running Mac; the agent reconnects and the screen is unchanged.
/// 2. Open Spotlight and type, so the screen differs.
/// 3. Restore the live snapshot: Spotlight is gone (memory came back).
/// 4. Reset to "Freshly set up", saving the current state first: cold boot from the clean disk.
/// 5. Restore that safety snapshot: back to step 3's screen.
/// Snapshots made here are deleted at the end; "Freshly set up" stays.
@MainActor
enum SnapshotTest {
    static func run() async throws {
        let bundle = VMProbe.bundle
        let secrets = bundle.secretStore()
        let controller = try VirtualMachineController(bundle: bundle)
        let vmID = controller.spec.id
        guard let token = try secrets.read(SecretAccount.pairingToken(vmID: vmID)) else {
            throw ProbeError("no pairing token in secrets.json")
        }
        let bridge = BridgeServer(vmID: vmID, pairingToken: token)
        controller.onSocketDeviceReady = { bridge.attach(to: $0) }
        let existing = Set(controller.snapshots.map(\.id))

        var started = Date()
        await controller.start()
        guard controller.state == .running else { throw ProbeError("start failed: \(controller.state)") }
        try await waitForDesktop(bridge, vmID: vmID, since: started, what: "first start")

        func send(_ command: GuestCommand, lease: UUID? = nil) async throws -> CommandResult {
            try await bridge.send(VMProbe.envelope(vmID, command, lease: lease))
        }
        func screen() async throws -> CGImage {
            guard case .screenshot(let shot) = try await send(.screenshot(region: nil)),
                  let source = CGImageSourceCreateWithData(shot.imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ProbeError("no screenshot") }
            return image
        }

        // 1. Live snapshot.
        let original = try await screen()
        started = Date()
        let live = try await controller.takeSnapshot(name: "harness: live", thumbnail: nil)
        VMProbe.log("1. live snapshot in \(VMProbe.elapsed(since: started)), memory \(live.memoryBytes.map { "\($0 >> 20) MB" } ?? "none")")
        try await waitForDesktop(bridge, vmID: vmID, since: started, what: "after live snapshot")
        VMProbe.log("   screen change across the snapshot: \(difference(original, try await screen()))")
        VMProbe.log("   snapshots: \(controller.snapshots.map { "\($0.name) [\($0.kind.rawValue)]" })")

        // 2. Change the screen.
        let lease = UUID()
        _ = try await send(.setLease(lease))
        _ = try await send(.perform(.key(combo: "cmd+space", repeat: 1)), lease: lease)
        try await Task.sleep(for: .seconds(1))
        _ = try await send(.perform(.type(text: "snapshot test")), lease: lease)
        try await Task.sleep(for: .seconds(1))
        _ = try await send(.setLease(nil))
        let changed = try await screen()
        VMProbe.log("2. screen change after Spotlight: \(difference(original, changed))")

        // 3. Restore the live snapshot.
        started = Date()
        try await controller.restoreSnapshot(live.id, savingCurrentAs: nil, thumbnail: nil)
        VMProbe.log("3. restored the live snapshot in \(VMProbe.elapsed(since: started))")
        try await waitForDesktop(bridge, vmID: vmID, since: started, what: "after restore")
        let restored = try await screen()
        VMProbe.log("   screen change from the snapshot: \(difference(original, restored)) (Spotlight screen: \(difference(changed, restored)))")

        // 4. Reset to the freshly set up Mac, saving the current state first.
        guard let initial = controller.snapshots.first(where: { $0.kind == .initial }) else { throw ProbeError("no initial snapshot") }
        started = Date()
        try await controller.restoreSnapshot(initial.id, savingCurrentAs: "harness: before reset", thumbnail: nil)
        VMProbe.log("4. reset to “\(initial.name)” in \(VMProbe.elapsed(since: started)) (cold boot)")
        try await waitForDesktop(bridge, vmID: vmID, since: started, what: "after reset", timeout: 300)

        // 5. Back to the state before the reset.
        guard let safety = controller.snapshots.first(where: { $0.name == "harness: before reset" }) else { throw ProbeError("no safety snapshot") }
        started = Date()
        try await controller.restoreSnapshot(safety.id, savingCurrentAs: nil, thumbnail: nil)
        VMProbe.log("5. restored the safety snapshot in \(VMProbe.elapsed(since: started))")
        try await waitForDesktop(bridge, vmID: vmID, since: started, what: "after undoing the reset")
        VMProbe.log("   screen change from step 3: \(difference(restored, try await screen()))")

        for snapshot in controller.snapshots where !existing.contains(snapshot.id) && snapshot.kind != .initial {
            try controller.deleteSnapshot(snapshot.id)
        }
        VMProbe.log("snapshots left: \(controller.snapshots.map(\.name)), current: \(controller.currentSnapshotID.map(\.uuidString) ?? "none")")
        try await VMProbe.shutdown(controller, bridge: bridge)
    }

    /// Waits until a fresh health check reports a ready desktop; a connection from before a restart fails it.
    private static func waitForDesktop(_ bridge: BridgeServer, vmID: UUID, since: Date, what: String, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await bridge.isConnected,
               case .health(let report)? = try? await bridge.send(CommandEnvelope(
                   vmID: vmID, jobID: nil, leaseToken: nil, observationVersion: nil,
                   deadline: Date().addingTimeInterval(3), command: .health)),
               report.isDesktopReady {
                VMProbe.log("   agent ready \(VMProbe.elapsed(since: since)) \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw ProbeError("agent not ready \(what) within \(Int(timeout)) s")
    }

    /// Mean absolute difference of two screenshots in grey levels (0–255), on a 160×100 thumbnail.
    private static func difference(_ a: CGImage, _ b: CGImage) -> String {
        func pixels(_ image: CGImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: 160 * 100)
            buffer.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 160,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 100))
            }
            return buffer
        }
        let total = zip(pixels(a), pixels(b)).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return String(format: "%.2f", Double(total) / 16000)
    }
}
#endif
