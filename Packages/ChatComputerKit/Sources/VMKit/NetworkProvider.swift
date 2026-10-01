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

    /// IPv4 subnet of the network, once created. Each network instance can get a different
    /// subnet (observed: 192.168.64.0/24 on one boot, 192.168.66.0/24 on the next).
    public var ipv4Subnet: IPv4Subnet? {
        guard let network else { return nil }
        var address = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(network, &address, &mask)
        guard address.s_addr != 0 else { return nil }
        return IPv4Subnet(address: UInt32(bigEndian: address.s_addr), mask: UInt32(bigEndian: mask.s_addr))
    }

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

/// Host-order IPv4 subnet.
public struct IPv4Subnet: Sendable, Equatable {
    public var address: UInt32
    public var mask: UInt32

    public init(address: UInt32, mask: UInt32) {
        self.address = address
        self.mask = mask
    }

    public init?(_ cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = UInt32(parts[1]), bits <= 32, let address = Self.parse(String(parts[0])) else { return nil }
        self.mask = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        self.address = address & mask
    }

    public func contains(_ ip: String) -> Bool {
        guard let value = Self.parse(ip) else { return false }
        return value & mask == address & mask
    }

    static func parse(_ ip: String) -> UInt32? {
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
#endif
