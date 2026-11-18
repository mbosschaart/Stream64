import Foundation
import Darwin

enum WakeOnLANService {
    static func packet(mac: String) throws -> Data {
        let parts = mac.replacingOccurrences(of: "-", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 }),
              parts.compactMap({ UInt8($0, radix: 16) }).count == 6 else {
            throw FileSystemError.invalidResponse("Enter a six-byte Wi-Fi MAC address")
        }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes != [UInt8](repeating: 0, count: 6), bytes[0] & 1 == 0 else {
            throw FileSystemError.invalidResponse("Wake requires the device's unicast Wi-Fi MAC address")
        }
        return Data([UInt8](repeating: 0xFF, count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 })
    }

    static func send(mac: String, address: String = "255.255.255.255", port: UInt16 = 9) throws {
        let data = try packet(mac: mac)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else { throw FileSystemError.unsafePath }
        let sent = withUnsafePointer(to: &destination) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                data.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard sent == data.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

enum DeviceNetworkIdentity {
    static func wifiMAC(for deviceID: UUID) -> String? {
        UserDefaults.standard.string(forKey: "wifiMAC.\(deviceID.uuidString)")
    }

    static func remember(_ info: UltimateAPIClient.DeviceInfo, for deviceID: UUID) {
        guard info.product?.localizedCaseInsensitiveContains("C64 Ultimate") == true,
              let mac = info.wifiMAC, (try? WakeOnLANService.packet(mac: mac)) != nil else { return }
        UserDefaults.standard.set(mac, forKey: "wifiMAC.\(deviceID.uuidString)")
    }
}
