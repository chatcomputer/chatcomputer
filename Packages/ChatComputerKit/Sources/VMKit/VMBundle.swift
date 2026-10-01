#if os(macOS)
import Foundation

/// Everything that defines one virtual Mac, kept together on disk (proposal §05: disk, auxiliary
/// storage, hardware model and machine identifier must always be managed as one matching set).
///
///     ChatComputer.vm/
///       spec.json               VMSpec
///       HardwareModel.bin
///       MachineIdentifier.bin
///       AuxiliaryStorage.bin
///       Disk/base.asif          golden image, read-only once frozen
///       Disk/overlay-N.asif     copy-on-write layers (DiskImageKit)
///       SavedState.vzvmsave     suspended VM memory, optional
///       known_hosts             pinned guest SSH host key (bootstrap only)
///       Shared/inbox|outbox     per-task folders shared over virtio-fs
///       Shared/bootstrap        agent installer, mounted read-only
public struct VMBundle: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultLocation: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatComputer", isDirectory: true)
            .appendingPathComponent("ChatComputer.vm", isDirectory: true)
    }

    public var specURL: URL { url.appendingPathComponent("spec.json") }
    public var hardwareModelURL: URL { url.appendingPathComponent("HardwareModel.bin") }
    public var machineIdentifierURL: URL { url.appendingPathComponent("MachineIdentifier.bin") }
    public var auxiliaryStorageURL: URL { url.appendingPathComponent("AuxiliaryStorage.bin") }
    public var diskDirectory: URL { url.appendingPathComponent("Disk", isDirectory: true) }
    public var baseDiskURL: URL { diskDirectory.appendingPathComponent("base.asif") }
    public func overlayURL(_ index: Int) -> URL { diskDirectory.appendingPathComponent("overlay-\(index).asif") }
    public var savedStateURL: URL { url.appendingPathComponent("SavedState.vzvmsave") }
    public var knownHostsURL: URL { url.appendingPathComponent("known_hosts") }
    public var sharedRoot: URL { url.appendingPathComponent("Shared", isDirectory: true) }
    public var bootstrapDirectory: URL { sharedRoot.appendingPathComponent("bootstrap", isDirectory: true) }

    public var exists: Bool { FileManager.default.fileExists(atPath: specURL.path) }

    public func create() throws {
        let fm = FileManager.default
        for directory in [url, diskDirectory, sharedRoot, bootstrapDirectory,
                          sharedRoot.appendingPathComponent("inbox"), sharedRoot.appendingPathComponent("outbox")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func loadSpec() throws -> VMSpec {
        try JSONDecoder().decode(VMSpec.self, from: Data(contentsOf: specURL))
    }

    public func save(_ spec: VMSpec) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(spec).write(to: specURL, options: .atomic)
    }
}

/// Resource and lifecycle settings for a VM. Secrets (guest password, pairing token) live in the Keychain.
public struct VMSpec: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable {
        case created          // platform files and blank disk exist
        case installed        // macOS installed, never booted
        case provisioned      // first boot done: user account, auto-login
        case agentInstalled   // guest agent running and paired
        case ready            // permissions granted, golden image frozen
    }

    public var id: UUID
    public var name: String
    public var stage: Stage
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    /// Display in pixels; with 2× density the guest sees half this size in points,
    /// which is the coordinate space screenshots and clicks use.
    public var displayWidth: Int
    public var displayHeight: Int
    public var displayPPI: Int
    public var macAddress: String
    public var guestUsername: String
    public var restoreImageBuild: String?
    /// Number of overlay layers on top of the base image; the last one is writable.
    public var overlayCount: Int

    public init(id: UUID = UUID(), name: String = "Chat Computer", cpuCount: Int = 4, memoryBytes: UInt64 = 8 << 30,
                diskBytes: UInt64 = 80 << 30, displayWidth: Int = 2560, displayHeight: Int = 1600, displayPPI: Int = 220,
                macAddress: String, guestUsername: String = "agent") {
        self.id = id
        self.name = name
        self.stage = .created
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.displayPPI = displayPPI
        self.macAddress = macAddress
        self.guestUsername = guestUsername
        self.restoreImageBuild = nil
        self.overlayCount = 0
    }
}
#endif
