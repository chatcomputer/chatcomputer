#if os(macOS)
import Foundation

public enum VMError: Error, Equatable, LocalizedError {
    case unsupportedHost(String)
    case noSupportedConfiguration
    case missingPlatformFile(String)
    case diskCreationFailed(status: Int32)
    case networkUnavailable(status: Int)
    case notRunning
    case guestAddressUnknown
    case bootstrapFailed(String)
    case restoreImageCatalogUnavailable(String)
    case shutdownTimedOut

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost(let detail): "This Mac can't run Chat Computer: \(detail)"
        case .noSupportedConfiguration: "The macOS restore image has no configuration this Mac supports."
        case .missingPlatformFile(let name): "The virtual machine is missing \(name)."
        case .diskCreationFailed(let status): "Creating the virtual disk failed (diskutil exit \(status))."
        case .networkUnavailable(let status): "The virtual network could not be created (vmnet status \(status))."
        case .notRunning: "The virtual machine is not running."
        case .guestAddressUnknown: "The virtual machine has no network address yet."
        case .bootstrapFailed(let detail): "Installing the guest agent failed: \(detail)"
        case .shutdownTimedOut: "The virtual Mac did not shut down in time."
        case .restoreImageCatalogUnavailable(let detail):
            "Apple's restore image catalog could not be loaded (\(detail)). Choose a downloaded macOS restore image (.ipsw) instead."
        }
    }
}
#endif
