#if os(macOS)
import Foundation
import Virtualization
import vmnet

/// Guest network built on vmnet custom networks (`VZVmnetNetworkDeviceAttachment`, macOS 26+).
///
/// vmnet networks are reference-counted and vanish when the app quits, so the provider owns
/// the network object for as long as the VM runs and rebuilds it from settings on every launch.
/// The control channel never uses this network (it goes over vsock).
public final class NetworkProvider: @unchecked Sendable {
    private var network: vmnet_network_ref?

    public init() {}

    public func makeDevice(macAddress: String) throws -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.macAddress = VZMACAddress(string: macAddress) ?? .randomLocallyAdministered()
        device.attachment = try makeAttachment()
        return device
    }

    private func makeAttachment() throws -> VZNetworkDeviceAttachment {
        if let network {
            return VZVmnetNetworkDeviceAttachment(network: network)
        }
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let configuration = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
            throw VMError.networkUnavailable(status: Int(status.rawValue))
        }
        // TODO(P5): pin the subnet / DHCP range so the guest address is predictable, and test whether
        // the guest can reach services listening on the host or the LAN (proposal §07). Document the result.
        guard let created = vmnet_network_create(configuration, &status) else {
            throw VMError.networkUnavailable(status: Int(status.rawValue))
        }
        network = created
        return VZVmnetNetworkDeviceAttachment(network: created)
    }
}
#endif
