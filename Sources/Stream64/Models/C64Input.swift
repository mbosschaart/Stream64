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
        case keyboard, joystick, mouse, releaseAll = "release_all"
    }

    let kind: Kind
    var inputs: [String]?
    var transition: C64InputTransition?
    var port: Int?
    var move: MouseMotion?
    var wheel: MouseWheel?

    struct MouseMotion: Codable, Equatable { let x: Int; let y: Int }
    struct MouseWheel: Codable, Equatable { let vertical: Int; let horizontal: Int }

    static func mouseMove(x: Int, y: Int) -> Self {
        Self(kind: .mouse, move: .init(x: x, y: y))
    }

    static func mouseWheel(vertical: Int, horizontal: Int) -> Self {
        Self(kind: .mouse, wheel: .init(vertical: vertical, horizontal: horizontal))
    }

    static func mouseButton(_ button: String, transition: C64InputTransition) -> Self {
        Self(kind: .mouse, inputs: [button], transition: transition)
    }

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
    case up, down, left, right, fire, fire2, fire3
}

enum JoystickFireKey: String, Codable, CaseIterable, Identifiable {
    case backquote = "Backquote (`)"
    case command = "Command"
    case control = "Control"
    case option = "Option"
    case space = "Space"
    var id: String { rawValue }
}

enum GamepadFireMapping: String, Codable, CaseIterable, Identifiable {
    case none = "None", fire = "Fire", fire2 = "Fire 2", fire3 = "Fire 3"
    var id: String { rawValue }
    var direction: JoystickDirection? {
        switch self {
        case .none: return nil
        case .fire: return .fire
        case .fire2: return .fire2
        case .fire3: return .fire3
        }
    }
}

enum ExtraFireKey: String, Codable, CaseIterable, Identifiable {
    case none = "None", z = "Z", x = "X", c = "C", space = "Space"
    var id: String { rawValue }
    var keyCode: UInt16? {
        switch self {
        case .none: return nil
        case .z: return 6
        case .x: return 7
        case .c: return 8
        case .space: return 49
        }
    }
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
    @Published var mouseEnabled: Bool { didSet { save() } }
    /// Live detection only; never persist hardware capabilities.
    @Published private(set) var mouseAvailable = false

    func updateMouseAvailability(_ available: Bool) {
        if mouseAvailable != available { mouseAvailable = available }
    }
    @Published var joystickPort: Int { didSet { save() } }
    @Published var joystickFireKey: JoystickFireKey { didSet { save() } }
    @Published var fire2Key: ExtraFireKey { didSet { save() } }
    @Published var fire3Key: ExtraFireKey { didSet { save() } }
    @Published var buttonA: GamepadFireMapping { didSet { save() } }
    @Published var buttonB: GamepadFireMapping { didSet { save() } }
    @Published var buttonX: GamepadFireMapping { didSet { save() } }
    @Published var buttonY: GamepadFireMapping { didSet { save() } }
    @Published var gameControllerEnabled: Bool { didSet { save() } }
    @Published var deadzone: Double { didSet { save() } }
    @Published private(set) var customKeymapName: String?
    private(set) var customMappings: [String: UInt8] = [:]
    @Published var capability: MachineInputCapability = .unknown
    @Published var connectedControllerName: String?
    @Published var servicesReady = false

    /// Assigns `capability` only when it changes. `@Published` fires on
    /// every write — including `.supported = .supported` after each
    /// successful matrix send — which used to rebuild the live viewer
    /// while joystick traffic was in flight.
    func updateCapability(_ value: MachineInputCapability) {
        guard capability != value else { return }
        capability = value
    }

    func updateConnectedControllerName(_ value: String?) {
        guard connectedControllerName != value else { return }
        connectedControllerName = value
    }

    private struct Snapshot: Codable {
        var transport: InputTransportPreference
        var keymap: C64KeymapChoice
        var joystickEnabled: Bool
        var mouseEnabled: Bool?
        var joystickPort: Int
        var joystickFireKey: JoystickFireKey?
        var fire2Key: ExtraFireKey?
        var fire3Key: ExtraFireKey?
        var buttonA: GamepadFireMapping?
        var buttonB: GamepadFireMapping?
        var buttonX: GamepadFireMapping?
        var buttonY: GamepadFireMapping?
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
            mouseEnabled = snapshot.mouseEnabled ?? false
            joystickPort = snapshot.joystickPort
            joystickFireKey = snapshot.joystickFireKey ?? .backquote
            fire2Key = snapshot.fire2Key ?? .none
            fire3Key = snapshot.fire3Key ?? .none
            buttonA = snapshot.buttonA ?? .fire
            buttonB = snapshot.buttonB ?? .none
            buttonX = snapshot.buttonX ?? .none
            buttonY = snapshot.buttonY ?? .none
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
            mouseEnabled = false
            joystickPort = 2
            joystickFireKey = .backquote
            fire2Key = .none; fire3Key = .none
            buttonA = .fire; buttonB = .none; buttonX = .none; buttonY = .none
            gameControllerEnabled = true
            deadzone = 0.35
            customKeymapName = nil
        }
    }

    private func save() {
        let snapshot = Snapshot(
            transport: transport, keymap: keymap,
            joystickEnabled: joystickEnabled,
            mouseEnabled: mouseEnabled,
            joystickPort: joystickPort == 1 ? 1 : 2,
            joystickFireKey: joystickFireKey,
            fire2Key: fire2Key, fire3Key: fire3Key,
            buttonA: buttonA, buttonB: buttonB, buttonX: buttonX, buttonY: buttonY,
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
