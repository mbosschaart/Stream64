import Foundation

enum DeviceActionTarget: Hashable {
    case device(UUID)
    case allConnected
}

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
    /// UDP port on which this machine receives the debug bus-trace stream
    /// (U64/U64 Elite only — see `DeviceSession.startDebugTrace`).
    var debugPort: Int = 11002
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

    enum CodingKeys: String, CodingKey {
        case id, name, host, apiPort, password
        case videoPort, audioPort, debugPort
        case autoConnect, notes, ultimateUniqueID
        case ftpPort, ftpUsername
    }

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        apiPort: Int = 80,
        password: String = "",
        videoPort: Int = 11000,
        audioPort: Int = 11001,
        debugPort: Int = 11002,
        autoConnect: Bool = true,
        notes: String = "",
        ultimateUniqueID: String? = nil,
        ftpPort: Int? = nil,
        ftpUsername: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.apiPort = apiPort
        self.password = password
        self.videoPort = videoPort
        self.audioPort = audioPort
        self.debugPort = debugPort
        self.autoConnect = autoConnect
        self.notes = notes
        self.ultimateUniqueID = ultimateUniqueID
        self.ftpPort = ftpPort
        self.ftpUsername = ftpUsername
    }

    /// Tolerant decode so older `devices.json` files (missing fields added in
    /// later releases) keep loading instead of being quarantined as corrupt
    /// and wiping the user's device list / per-device settings after an update.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        apiPort = try container.decodeIfPresent(Int.self, forKey: .apiPort) ?? 80
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        videoPort = try container.decodeIfPresent(Int.self, forKey: .videoPort) ?? 11000
        audioPort = try container.decodeIfPresent(Int.self, forKey: .audioPort) ?? 11001
        debugPort = try container.decodeIfPresent(Int.self, forKey: .debugPort) ?? 11002
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        ultimateUniqueID = try container.decodeIfPresent(
            String.self, forKey: .ultimateUniqueID)
        ftpPort = try container.decodeIfPresent(Int.self, forKey: .ftpPort)
        ftpUsername = try container.decodeIfPresent(
            String.self, forKey: .ftpUsername)
    }

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

    /// User-facing validation for remote service ports plus the three local
    /// UDP listeners. Local stream ports must also be unique across devices;
    /// otherwise SO_REUSEPORT lets the kernel split incompatible packets
    /// between receivers instead of reporting a bind failure.
    func portValidationIssue(
        among devices: [UltimateDevice]
    ) -> String? {
        let validRange = 1...65_535
        guard validRange.contains(apiPort) else {
            return "API Port must be between 1 and 65535."
        }
        guard validRange.contains(effectiveFTPPort) else {
            return "FTP Port must be between 1 and 65535."
        }

        let localPorts = [videoPort, audioPort, debugPort]
        guard localPorts.allSatisfy(validRange.contains) else {
            return "Video, Audio, and Debug ports must be between 1 and 65535."
        }
        guard Set(localPorts).count == localPorts.count else {
            return "Video, Audio, and Debug ports must be different."
        }

        let otherPorts = Set(
            devices
                .filter { $0.id != id }
                .flatMap { [$0.videoPort, $0.audioPort, $0.debugPort] })
        if let collision = localPorts.first(where: otherPorts.contains) {
            return "Local stream port \(collision) is already used by another device."
        }
        return nil
    }

    static func makeDefault() -> UltimateDevice {
        UltimateDevice(name: "My Ultimate 64", host: "")
    }

    /// Default for a new device with local UDP ports not used by any
    /// existing device — every device needs its own receive ports for
    /// simultaneous streaming. Allocates video/audio/debug as a triplet so
    /// the debug port never collides with another device's video or audio
    /// port either.
    static func makeDefault(avoiding existing: [UltimateDevice]) -> UltimateDevice {
        var device = makeDefault()
        let used = Set(existing.flatMap { [$0.videoPort, $0.audioPort, $0.debugPort] })
        var port = 11000
        while used.contains(port) || used.contains(port + 1) || used.contains(port + 2) {
            port += 3
        }
        device.videoPort = port
        device.audioPort = port + 1
        device.debugPort = port + 2
        return device
    }
}
