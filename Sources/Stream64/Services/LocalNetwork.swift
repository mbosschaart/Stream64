import Foundation
import Darwin

/// Local IPv4 interface enumeration and bounded subnet expansion shared by
/// stream routing and automatic Ultimate discovery.
enum LocalNetwork {
    struct IPv4Interface: Equatable {
        let name: String
        let address: String
        let netmask: String

        var isEthernetOrWiFi: Bool { name.hasPrefix("en") }
    }

    /// Returns this Mac's best routable IPv4 address to use as the stream
    /// destination for a given device IP. Selection priority:
    /// same-subnet en*, same-subnet other, routable en*, routable other.
    static func primaryIPv4Address(
        reachingDevice deviceIP: String? = nil
    ) -> String? {
        interfaces().sorted { lhs, rhs in
            let lhsSame = deviceIP.map {
                sameSubnet(lhs.address, $0, mask: lhs.netmask)
            } ?? false
            let rhsSame = deviceIP.map {
                sameSubnet(rhs.address, $0, mask: rhs.netmask)
            } ?? false
            if lhsSame != rhsSame { return lhsSame }
            return lhs.isEthernetOrWiFi && !rhs.isEthernetOrWiFi
        }.first?.address
    }

    /// Active, routable IPv4 interfaces. VPN/tunnel interfaces are omitted
    /// unless explicitly requested so discovery does not scan remote ranges.
    static func interfaces(includeVPN: Bool = false) -> [IPv4Interface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var result: [IPv4Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  let netmaskPointer = interface.ifa_netmask else { continue }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_POINTOPOINT == 0 else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            if !includeVPN && isTunnelInterface(name) { continue }

            guard let address = numericAddress(addressPointer),
                  let netmask = numericAddress(netmaskPointer),
                  address != "0.0.0.0",
                  !address.hasPrefix("127."),
                  !address.hasPrefix("169.254.") else { continue }

            let candidate = IPv4Interface(
                name: name, address: address, netmask: netmask)
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    /// Expands active interfaces into a safe scan list. Networks broader than
    /// /24 are intentionally restricted to the local address's /24, avoiding
    /// thousands of probes on enterprise, VPN, or misconfigured interfaces.
    static func discoveryHosts(
        for interfaces: [IPv4Interface] = interfaces(),
        maximumHostsPerInterface: Int = 254
    ) -> [String] {
        var seen = Set<UInt32>()
        var hosts: [UInt32] = []
        let localAddresses = Set(interfaces.compactMap {
            ipv4Integer($0.address)
        })

        for interface in interfaces {
            guard let address = ipv4Integer(interface.address),
                  let mask = ipv4Integer(interface.netmask) else { continue }
            let prefixLength = mask.nonzeroBitCount
            let scanMask: UInt32 = prefixLength < 24 ? 0xFFFFFF00 : mask
            let network = address & scanMask
            let broadcast = network | ~scanMask
            guard broadcast > network + 1 else { continue }

            var count = 0
            var host = network + 1
            while host < broadcast && count < maximumHostsPerInterface {
                if !localAddresses.contains(host), seen.insert(host).inserted {
                    hosts.append(host)
                    count += 1
                }
                host += 1
            }
        }

        return hosts.sorted().map(ipv4String)
    }

    static func sameSubnet(_ a: String, _ b: String, mask: String) -> Bool {
        guard let lhs = ipv4Integer(a),
              let rhs = ipv4Integer(b),
              let netmask = ipv4Integer(mask) else { return false }
        return (lhs & netmask) == (rhs & netmask)
    }

    private static func numericAddress(
        _ pointer: UnsafeMutablePointer<sockaddr>
    ) -> String? {
        var address = pointer.pointee
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            &address, socklen_t(pointer.pointee.sa_len),
            &buffer, socklen_t(buffer.count),
            nil, 0, NI_NUMERICHOST
        ) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func isTunnelInterface(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains {
            name.hasPrefix($0)
        }
    }

    private static func ipv4Integer(_ string: String) -> UInt32? {
        let octets = string.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func ipv4String(_ value: UInt32) -> String {
        [
            String((value >> 24) & 0xFF),
            String((value >> 16) & 0xFF),
            String((value >> 8) & 0xFF),
            String(value & 0xFF),
        ].joined(separator: ".")
    }
}
