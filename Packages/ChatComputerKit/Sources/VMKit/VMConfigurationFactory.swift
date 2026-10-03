#if os(macOS)
import Foundation
import Virtualization

/// Builds the `VZVirtualMachineConfiguration` for a bundle. One place, so the platform files,
/// disk stack and devices always match each other.
public struct VMConfigurationFactory {
    public let bundle: VMBundle
    public let network: NetworkProvider

    public init(bundle: VMBundle, network: NetworkProvider) {
        self.bundle = bundle
        self.network = network
    }

    /// `shares` are the user's folders; `includeBootstrap` adds the agent installer, which is only needed
    /// while the agent is installed or updated.
    public func make(spec: VMSpec, shares: [UserShare] = [], includeBootstrap: Bool = true) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.platform = try platform()
        configuration.cpuCount = spec.cpuCount
        configuration.memorySize = spec.memoryBytes

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: spec.displayWidth, heightInPixels: spec.displayHeight, pixelsPerInch: spec.displayPPI)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]

        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try DiskStack(bundle: bundle).makeAttachment(spec: spec))]
        configuration.networkDevices = [try network.makeDevice(macAddress: spec.macAddress)]

        // Control channel to the guest agent (BridgeProtocol over vsock).
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // One device with a fixed tag; macOS mounts it as "/Volumes/My Shared Files". Its folders can be
        // changed while the VM runs (`VirtualMachineController.applyShares`).
        let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        device.share = directoryShare(shares: shares, includeBootstrap: includeBootstrap)
        configuration.directorySharingDevices = [device]

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try configuration.validate()
        if #available(macOS 14, *) {
            try configuration.validateSaveRestoreSupport()
        }
        return configuration
    }

    /// Task folders, the user's folders that still exist, and optionally the agent installer.
    public func directoryShare(shares: [UserShare], includeBootstrap: Bool) -> VZMultipleDirectoryShare {
        var directories: [String: VZSharedDirectory] = [
            "inbox": VZSharedDirectory(url: bundle.sharedRoot.appendingPathComponent("inbox"), readOnly: true),
            "outbox": VZSharedDirectory(url: bundle.sharedRoot.appendingPathComponent("outbox"), readOnly: false),
        ]
        if includeBootstrap {
            directories["bootstrap"] = VZSharedDirectory(url: bundle.bootstrapDirectory, readOnly: true)
        }
        for share in shares where share.exists && !SharePolicy.reservedNames.contains(share.name.lowercased()) {
            directories[share.name] = VZSharedDirectory(url: share.url, readOnly: share.readOnly)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }

    private func platform() throws -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()
        guard let hardwareData = try? Data(contentsOf: bundle.hardwareModelURL),
              let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw VMError.missingPlatformFile("HardwareModel.bin")
        }
        guard hardwareModel.isSupported else { throw VMError.unsupportedHost("hardware model not supported") }
        guard let identifierData = try? Data(contentsOf: bundle.machineIdentifierURL),
              let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
            throw VMError.missingPlatformFile("MachineIdentifier.bin")
        }
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        return platform
    }
}
#endif
