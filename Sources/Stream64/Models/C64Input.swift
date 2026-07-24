import Foundation
import Combine

enum InputTransportPreference: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case matrix = "Matrix"
    case legacy = "Legacy"
    var id: String { rawValue }
}

enum C64KeymapChoice: String, Codable, CaseIterable, Identifiable {
    case symbolic = "Symbolic", positional = "Positional"
    case custom = "Custom"
    var id: String { rawValue }
}

enum MachineInputCapability: Equatable {
    case unknown
    case probing
    case supported
    case legacyFallback
    case unsupported(String)
    case failed(String)

    var label: String {
        switch self {
        case .unknown: return "Not checked"
        case .probing: return "Checking…"
        case .supported: return "Matrix input ready"
        case .legacyFallback: return "Legacy keyboard fallback"
        case .unsupported(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}

enum C64InputTransition: String, Codable {
    case tap, press, release
}

struct C64MachineInputEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case keyboard, joystick, releaseAll = "release_all"
    }

    let kind: Kind
    var inputs: [String]?
    var transition: C64InputTransition?
    var port: Int?

    static func keyboard(
        _ inputs: [String],
        transition: C64InputTransition
    ) -> Self {
        Self(kind: .keyboard, inputs: inputs,
             transition: transition, port: nil)
    }

    static func joystick(
        _ input: String,
        port: Int,
        transition: C64InputTransition
    ) -> Self {
        Self(kind: .joystick, inputs: [input],
             transition: transition, port: port)
    }

    static let releaseAll = Self(
        kind: .releaseAll, inputs: nil, transition: nil, port: nil)
}

struct C64MachineInputEnvelope: Codable, Equatable {
    let events: [C64MachineInputEvent]
}

enum JoystickDirection: String, CaseIterable, Hashable {
    case up, down, left, right, fire
}

enum JoystickFireKey: String, Codable, CaseIterable, Identifiable {
    case backquote = "Backquote (`)"
    case command = "Command"
    case control = "Control"
    case option = "Option"
    case space = "Space"
    var id: String { rawValue }
}

@MainActor
final class InputSettings: ObservableObject {
    private static var instances: [UUID: InputSettings] = [:]

    static func shared(for deviceID: UUID) -> InputSettings {
        if let existing = instances[deviceID] { return existing }
        let created = InputSettings(deviceID: deviceID)
        instances[deviceID] = created
        return created
    }

    let deviceID: UUID
    @Published var transport: InputTransportPreference { didSet { save() } }
    @Published var keymap: C64KeymapChoice { didSet { save() } }
    @Published var joystickEnabled: Bool { didSet { save() } }
    @Published var joystickPort: Int { didSet { save() } }
    @Published var joystickFireKey: JoystickFireKey { didSet { save() } }
    @Published var gameControllerEnabled: Bool { didSet { save() } }
    @Published var deadzone: Double { didSet { save() } }
    @Published private(set) var customKeymapName: String?
    private(set) var customMappings: [String: UInt8] = [:]
    @Published var capability: MachineInputCapability = .unknown
    @Published var connectedControllerName: String?
    @Published var servicesReady = false

    private struct Snapshot: Codable {
        var transport: InputTransportPreference
        var keymap: C64KeymapChoice
        var joystickEnabled: Bool
        var joystickPort: Int
        var joystickFireKey: JoystickFireKey?
        var gameControllerEnabled: Bool
        var deadzone: Double
        var customKeymapPath: String?
    }

    private init(deviceID: UUID) {
        self.deviceID = deviceID
        if let data = UserDefaults.standard.data(
            forKey: "inputSettings.\(deviceID.uuidString)"),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            transport = snapshot.transport
            keymap = snapshot.keymap
            joystickEnabled = snapshot.joystickEnabled
            joystickPort = snapshot.joystickPort
            joystickFireKey = snapshot.joystickFireKey ?? .backquote
            gameControllerEnabled = snapshot.gameControllerEnabled
            deadzone = snapshot.deadzone
            if let path = snapshot.customKeymapPath,
               let text = try? String(contentsOfFile: path),
               let map = try? C64KeymapFile.parse(text) {
                customKeymapName = map.name
                customMappings = map.mappings
            } else {
                customKeymapName = nil
            }
        } else {
            transport = .auto
            keymap = .symbolic
            joystickEnabled = false
            joystickPort = 2
            joystickFireKey = .backquote
            gameControllerEnabled = true
            deadzone = 0.35
            customKeymapName = nil
        }
    }

    private func save() {
        let snapshot = Snapshot(
            transport: transport, keymap: keymap,
            joystickEnabled: joystickEnabled,
            joystickPort: joystickPort == 1 ? 1 : 2,
            joystickFireKey: joystickFireKey,
            gameControllerEnabled: gameControllerEnabled,
            deadzone: min(max(deadzone, 0.05), 0.9),
            customKeymapPath: UserDefaults.standard.string(
                forKey: "inputKeymapPath.\(deviceID.uuidString)"))
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(
                data, forKey: "inputSettings.\(deviceID.uuidString)")
        }
    }

    func importKeymap(from url: URL) throws {
        let text = try String(contentsOf: url)
        let map = try C64KeymapFile.parse(text)
        customMappings = map.mappings
        customKeymapName = map.name
        keymap = .custom
        UserDefaults.standard.set(
            url.path, forKey: "inputKeymapPath.\(deviceID.uuidString)")
        save()
    }
}
