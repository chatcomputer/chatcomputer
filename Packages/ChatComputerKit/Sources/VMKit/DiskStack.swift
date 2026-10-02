#if os(macOS)
import Foundation
import DiskImageKit
import Virtualization

/// Layered guest disk built on DiskImageKit (macOS 27).
///
/// - base: the golden image (macOS + provisioned account + guest agent), read-only once frozen.
/// - overlays: ASIF copy-on-write layers; the topmost is writable.
///
/// Snapshots (`SnapshotStore`) are APFS clones of the overlays, so the stack itself stays one layer deep.
/// Stacks should stay shallow (WWDC26 session 224).
///
/// API names follow WWDC26 session 224 and must be checked against the Xcode 27 SDK (probe P4).
public struct DiskStack: Sendable {
    public let bundle: VMBundle

    public init(bundle: VMBundle) {
        self.bundle = bundle
    }

    /// Creates the empty base disk before installation.
    /// `diskutil image create` produces ASIF since macOS 26; swap for a DiskImageKit creation call once verified.
    public func createBlankBase(bytes: UInt64) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["image", "create", "blank", "--fs", "none", "--format", "ASIF",
                             "--size", "\(bytes / (1 << 30))G", bundle.baseDiskURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VMError.diskCreationFailed(status: process.terminationStatus)
        }
    }

    /// Storage attachment for the current spec: base alone before freezing, base + overlays after.
    public func makeAttachment(spec: VMSpec) throws -> VZStorageDeviceAttachment {
        guard spec.overlayCount > 0 else {
            return try VZDiskImageStorageDeviceAttachment(url: bundle.baseDiskURL, readOnly: false)
        }
        var image = try DiskImage(opening: .open(url: bundle.baseDiskURL, mode: .readOnly))
        for index in 1...spec.overlayCount {
            let url = bundle.overlayURL(index)
            let layer = index == spec.overlayCount
                ? try DiskImage(opening: .open(url: url))
                : try DiskImage(opening: .open(url: url, mode: .readOnly))
            image = try image.appending(layer)
        }
        return try VZDiskImageStorageDeviceAttachment(diskImage: image)
    }

    /// Adds a new writable overlay on top of the current stack. Call with the VM stopped.
    /// Used to freeze the golden image after onboarding.
    public func pushOverlay(spec: inout VMSpec) throws {
        let next = spec.overlayCount + 1
        try createOverlay(at: bundle.overlayURL(next), above: spec.overlayCount)
        spec.overlayCount = next
    }

    /// Creates an empty copy-on-write layer at `url` on top of the base and the first `count` overlays,
    /// without adding it to the spec. Snapshots use it to record the freshly set up state. Call with the VM stopped.
    public func createOverlay(at url: URL, above count: Int) throws {
        var image = try DiskImage(opening: .open(url: bundle.baseDiskURL, mode: .readOnly))
        for index in stride(from: 1, through: count, by: 1) {
            image = try image.appending(DiskImage(opening: .open(url: bundle.overlayURL(index), mode: .readOnly)))
        }
        // TODO(P4): confirm the layer type name for a copy-on-write overlay (`.cache` is shown in the session).
        _ = try image.appending(.asifLayer(url: url, type: .overlay))
    }

    /// Drops every overlay above `keeping` and adds a fresh writable one. After freezing, overlay 1 is the
    /// writable layer on the golden base, so `keeping: 0` returns to the freshly onboarded state.
    public func discardOverlays(spec: inout VMSpec, keeping: Int) throws {
        guard spec.overlayCount > keeping else { return }
        for index in (keeping + 1)...spec.overlayCount {
            try? FileManager.default.removeItem(at: bundle.overlayURL(index))
        }
        spec.overlayCount = keeping
        // The writable top layer must be fresh, so recreate one empty overlay.
        try pushOverlay(spec: &spec)
    }
}
#endif
