#if os(macOS)
import ChatCore
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
///       Snapshots/              saved states of the whole machine (`SnapshotStore`)
///       known_hosts             pinned guest SSH host key (bootstrap only)
///       Shared/inbox|outbox     per-task folders shared over virtio-fs
///       Shared/bootstrap        agent installer, mounted read-only
public struct VMBundle: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The app's virtual Mac, in the data folder (`DataDirectory`).
    public static var defaultLocation: URL {
        DataDirectory.current.appendingPathComponent("ChatComputer.vm", isDirectory: true)
    }

    public var specURL: URL { url.appendingPathComponent("spec.json") }
    public var hardwareModelURL: URL { url.appendingPathComponent("HardwareModel.bin") }
    public var machineIdentifierURL: URL { url.appendingPathComponent("MachineIdentifier.bin") }
    public var auxiliaryStorageURL: URL { url.appendingPathComponent("AuxiliaryStorage.bin") }
    public var diskDirectory: URL { url.appendingPathComponent("Disk", isDirectory: true) }
    public var baseDiskURL: URL { diskDirectory.appendingPathComponent("base.asif") }
    public func overlayURL(_ index: Int) -> URL { diskDirectory.appendingPathComponent("overlay-\(index).asif") }
    public var savedStateURL: URL { url.appendingPathComponent("SavedState.vzvmsave") }
    /// The macOS restore image the machine was installed from: downloaded, or a hard link to one the user chose.
    public var restoreImageURL: URL { url.appendingPathComponent("RestoreImage.ipsw") }
    /// Guest password and pairing token (0600), shared by the app and `cc-harness`.
    public var secretsURL: URL { url.appendingPathComponent("secrets.json") }
    public var snapshotsDirectory: URL { url.appendingPathComponent("Snapshots", isDirectory: true) }
    public var knownHostsURL: URL { url.appendingPathComponent("known_hosts") }
    public var sharedRoot: URL { url.appendingPathComponent("Shared", isDirectory: true) }
    public var bootstrapDirectory: URL { sharedRoot.appendingPathComponent("bootstrap", isDirectory: true) }

    /// The bundle's secrets file.
    public func secretStore() -> FileSecretStore {
        FileSecretStore(url: secretsURL)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: specURL.path) }

    /// Takes the bundle's lock for the life of this process, so two processes (two copies of the app, or the
    /// app and `cc-harness`) never run the same machine on the same disk. Returns false if another holds it.
    public func lock() -> Bool {
        let fd = open(url.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        // Deliberately kept open: the kernel releases the lock when the process exits.
        return true
    }

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
        try Self.encode(spec).write(to: specURL, options: .atomic)
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateFormat))
        }
        return try encoder.encode(value)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try dateFormat.parse(decoder.singleValueContainer().decode(String.self))
        }
        return decoder
    }

    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// Resource and lifecycle settings for a VM. Secrets (guest password, pairing token) live in the bundle's secrets.json.
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
    /// The macOS release chosen at setup. Missing in bundles made before 0.9.9, which are all macOS 27.
    public var guestRelease: GuestRelease?
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

    public var release: GuestRelease { guestRelease ?? .macOS27 }
}

/// The macOS release a virtual Mac runs. macOS 27 is the default; macOS 26 is offered for testing on the previous
/// release.
public enum GuestRelease: String, Codable, Sendable, CaseIterable {
    case macOS27 = "27"
    case macOS26 = "26"

    public var title: String {
        switch self {
        case .macOS27: "macOS 27"
        case .macOS26: "macOS 26"
        }
    }

    /// macOS 27 creates the account on first boot (`VZMacGuestProvisioningOptions`); on macOS 26 the guest
    /// ignores those options and starts Setup Assistant, which the host walks through instead.
    public var supportsFirstBootProvisioning: Bool { self == .macOS27 }

    /// A pinned image for releases the restore image catalog no longer offers; nil means the latest supported.
    public var pinnedRestoreImage: URL? {
        switch self {
        case .macOS27: nil
        case .macOS26: URL(string: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw")
        }
    }
}
#endif
