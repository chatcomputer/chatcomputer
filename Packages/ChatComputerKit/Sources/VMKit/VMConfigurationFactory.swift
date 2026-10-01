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

    public func make(spec: VMSpec) throws -> VZVirtualMachineConfiguration {
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

        // Task folders and the agent installer. Mounted by macOS under "/Volumes/My Shared Files".
        let shares = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        shares.share = VZMultipleDirectoryShare(directories: [
            "inbox": VZSharedDirectory(url: bundle.sharedRoot.appendingPathComponent("inbox"), readOnly: true),
            "outbox": VZSharedDirectory(url: bundle.sharedRoot.appendingPathComponent("outbox"), readOnly: false),
            "bootstrap": VZSharedDirectory(url: bundle.bootstrapDirectory, readOnly: true),
        ])
        configuration.directorySharingDevices = [shares]

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try configuration.validate()
        if #available(macOS 14, *) {
            try configuration.validateSaveRestoreSupport()
        }
        return configuration
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
