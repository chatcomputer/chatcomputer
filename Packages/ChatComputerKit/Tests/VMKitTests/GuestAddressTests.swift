#if os(macOS)
import Testing
@testable import VMKit

@Suite struct GuestAddressTests {
    // Shape of /var/db/dhcpd_leases as observed on macOS 27: two leases for the same MAC
    // from different boots, on different subnets, plus another VM's lease.
    let leases = """
        {
        	name=ChatsVilMachine
        	ip_address=192.168.64.6
        	hw_address=1,aa:b2:89:ce:ca:c9
        	identifier=1,aa:b2:89:ce:ca:c9
        	lease=0x6abbc887
        }
        {
        	name=omarchy
        	ip_address=192.168.66.3
        	hw_address=1,fa:d3:1:6a:2b:d1
        	identifier=1,fa:d3:1:6a:2b:d1
        	lease=0x6abdffff
        }
        {
        	name=ChatsVilMachine
        	ip_address=192.168.66.2
        	hw_address=1,aa:b2:89:ce:ca:c9
        	identifier=1,aa:b2:89:ce:ca:c9
        	lease=0x6abdfe6c
        }
        """

    @Test func picksLeaseInsideCurrentSubnet() {
        let subnet = IPv4Subnet("192.168.66.0/24")
        #expect(GuestProvisioner.leaseAddress(in: leases, macAddress: "aa:b2:89:ce:ca:c9", subnet: subnet) == "192.168.66.2")
        #expect(GuestProvisioner.leaseAddress(in: leases, macAddress: "aa:b2:89:ce:ca:c9", subnet: IPv4Subnet("192.168.64.0/24")) == "192.168.64.6")
    }

    @Test func withoutSubnetTheNewestLeaseWins() {
        #expect(GuestProvisioner.leaseAddress(in: leases, macAddress: "AA:B2:89:CE:CA:C9", subnet: nil) == "192.168.66.2")
    }

    @Test func macOctetsMatchWithoutLeadingZeros() {
        #expect(GuestProvisioner.leaseAddress(in: leases, macAddress: "fa:d3:01:6a:2b:d1", subnet: nil) == "192.168.66.3")
        #expect(GuestProvisioner.leaseAddress(in: leases, macAddress: "00:11:22:33:44:55", subnet: nil) == nil)
    }

    @Test func subnetParsing() {
        let subnet = IPv4Subnet("10.1.2.99/16")
        #expect(subnet?.contains("10.1.200.4") == true)
        #expect(subnet?.contains("10.2.0.1") == false)
        #expect(IPv4Subnet("nonsense") == nil)
    }
}
#endif
