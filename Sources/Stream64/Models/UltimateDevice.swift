import Foundation

/// A configured Commodore 64 Ultimate (Ultimate 64 / Ultimate-II+) device.
struct UltimateDevice: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    /// Port of the Ultimate's REST API (default 80).
    var apiPort: Int = 80
    /// Optional API password (Ultimate firmware supports password protection).
    var password: String = ""
    /// UDP port on which this machine receives the video stream.
    var videoPort: Int = 11000
    /// UDP port on which this machine receives the audio stream.
    var audioPort: Int = 11001
    /// Automatically connect and start streaming when the device is selected.
    var autoConnect: Bool = true
    var notes: String = ""
    /// Stable hardware identity reported by `/v1/info`, when discovered.
    /// The app UUID remains the identity for sessions and persisted settings.
    var ultimateUniqueID: String? = nil
    /// Optional FTP overrides. Nil preserves compatibility and uses the
    /// Ultimate defaults: port 21, anonymous login when no password is set.
    var ftpPort: Int? = nil
    var ftpUsername: String? = nil

    var effectiveFTPPort: Int { ftpPort ?? 21 }
    var effectiveFTPUsername: String {
        if let ftpUsername, !ftpUsername.isEmpty { return ftpUsername }
        return password.isEmpty ? "anonymous" : "admin"
    }

    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = apiPort == 80 ? nil : apiPort
        return components.url
    }

    var displayAddress: String {
        apiPort == 80 ? host : "\(host):\(apiPort)"
    }

    static func makeDefault() -> UltimateDevice {
        UltimateDevice(name: "My Ultimate 64", host: "")
    }

    /// Default for a new device with local UDP ports not used by any
    /// existing device — every device needs its own receive ports for
    /// simultaneous streaming.
    static func makeDefault(avoiding existing: [UltimateDevice]) -> UltimateDevice {
        var device = makeDefault()
        let used = Set(existing.flatMap { [$0.videoPort, $0.audioPort] })
        var port = 11000
        while used.contains(port) || used.contains(port + 1) {
            port += 2
        }
        device.videoPort = port
        device.audioPort = port + 1
        return device
    }
}
