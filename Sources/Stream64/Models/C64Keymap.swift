import Foundation
import AppKit

struct HostKeyInput: Equatable {
    let keyCode: UInt16
    let characters: String?
    let modifiers: NSEvent.ModifierFlags
    let isRepeat: Bool
}

struct C64KeyBinding: Equatable {
    let inputs: [String]
    let fallback: UInt8?
    let holdable: Bool
}

enum C64HostAction: Equatable {
    case key(C64KeyBinding)
    case toggleJoystick
    case toggleJoystickPort
    case joystick(JoystickDirection)
    case passthrough
}

enum C64HostKeyMapper {
    @MainActor
    static func action(
        for event: HostKeyInput,
        settings: InputSettings
    ) -> C64HostAction {
        if event.modifiers.contains(.command) { return .passthrough }
        if event.keyCode == 109 { return .toggleJoystick }     // F10
        if event.keyCode == 103 { return .toggleJoystickPort } // F11

        if settings.joystickEnabled {
            if (settings.joystickFireKey == .backquote
                    && event.keyCode == 50)
                || (settings.joystickFireKey == .space
                    && event.keyCode == 49) {
                return .joystick(.fire)
            }
            switch event.keyCode {
            case 123: return .joystick(.left)
            case 124: return .joystick(.right)
            case 125: return .joystick(.down)
            case 126: return .joystick(.up)
            default: break
            }
        }

        if settings.keymap == .custom,
           let identifier = customIdentifier(event),
           let code = settings.customMappings[identifier],
           let chord = C64MatrixMapper.chord(for: code) {
            return .key(C64KeyBinding(
                inputs: chord, fallback: code,
                holdable: chord.count == 1))
        }

        if settings.keymap == .positional,
           let inputs = positionalInputs(event) {
            let fallback = positionalFallback(event)
            return .key(C64KeyBinding(
                inputs: inputs, fallback: fallback,
                holdable: inputs.count == 1))
        }

        if let code = specialPETSCII(event)
            ?? event.characters.flatMap({ PETSCII.encode($0).first }),
           let chord = C64MatrixMapper.chord(for: code) {
            return .key(C64KeyBinding(
                inputs: chord, fallback: code,
                holdable: chord.count == 1))
        }
        return .passthrough
    }

    static func positionalModifier(
        keyCode: UInt16
    ) -> String? {
        switch keyCode {
        case 56: return "left_shift"
        case 60: return "right_shift"
        case 59, 62: return "ctrl"
        case 58, 61: return "commodore"
        default: return nil
        }
    }

    static func joystickModifier(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        enabled: Bool,
        fireKey: JoystickFireKey
    ) -> (input: JoystickDirection, pressed: Bool)? {
        guard enabled else {
            return nil
        }
        switch fireKey {
        case .command where keyCode == 54 || keyCode == 55:
            return (.fire, modifiers.contains(.command))
        case .control where keyCode == 59 || keyCode == 62:
            return (.fire, modifiers.contains(.control))
        case .option where keyCode == 58 || keyCode == 61:
            return (.fire, modifiers.contains(.option))
        default:
            return nil
        }
    }

    private static func specialPETSCII(_ event: HostKeyInput) -> UInt8? {
        let shifted = event.modifiers.contains(.shift)
        switch event.keyCode {
        case 36: return 0x0D
        case 51: return shifted ? 0x94 : 0x14
        case 53: return 0x03
        case 123: return 0x9D
        case 124: return 0x1D
        case 125: return 0x11
        case 126: return 0x91
        case 115: return shifted ? 0x93 : 0x13
        case 122: return shifted ? 0x89 : 0x85
        case 120: return 0x89
        case 99: return shifted ? 0x8A : 0x86
        case 118: return 0x8A
        case 96: return shifted ? 0x8B : 0x87
        case 97: return 0x8B
        case 98: return shifted ? 0x8C : 0x88
        case 100: return 0x8C
        default: return nil
        }
    }

    private static let positionalNames: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g",
        6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q",
        13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l",
        38: "j", 40: "k", 45: "n", 46: "m",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        49: "space", 36: "return", 53: "run_stop",
        123: "cursor_left_right", 124: "cursor_left_right",
        125: "cursor_up_down", 126: "cursor_up_down",
        24: "equals", 27: "minus", 43: "comma", 47: "period",
        44: "slash", 41: "semicolon", 39: "colon", 33: "at",
        42: "arrow_up", 50: "arrow_left",
    ]

    private static func positionalInputs(
        _ event: HostKeyInput
    ) -> [String]? {
        guard let key = positionalNames[event.keyCode] else { return nil }
        let needsShift: Bool
        switch event.keyCode {
        case 123, 126: needsShift = true
        default: needsShift = event.modifiers.contains(.shift)
        }
        return needsShift ? ["left_shift", key] : [key]
    }

    private static func positionalFallback(
        _ event: HostKeyInput
    ) -> UInt8? {
        specialPETSCII(event)
            ?? event.characters.flatMap { PETSCII.encode($0).first }
    }

    private static func customIdentifier(
        _ event: HostKeyInput
    ) -> String? {
        let special: [UInt16: String] = [
            36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace",
            53: "Escape", 115: "Home", 117: "Delete",
            119: "End", 116: "PageUp", 121: "PageDown",
            123: "ArrowLeft", 124: "ArrowRight",
            125: "ArrowDown", 126: "ArrowUp",
            122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        var key = special[event.keyCode]
        if key == nil, let character = event.characters?.first {
            if character.isLetter {
                key = "Key\(String(character).uppercased())"
            } else if character.isNumber {
                key = "Digit\(character)"
            }
        }
        guard let key else { return nil }
        var prefixes: [String] = []
        if event.modifiers.contains(.shift) { prefixes.append("Shift") }
        if event.modifiers.contains(.control) { prefixes.append("Ctrl") }
        if event.modifiers.contains(.option) { prefixes.append("Alt") }
        return (prefixes + [key]).joined(separator: "+")
    }
}

struct C64KeymapFile {
    let name: String
    let type: C64KeymapChoice
    let mappings: [String: UInt8]

    static func parse(_ text: String) throws -> C64KeymapFile {
        var section = ""
        var name = "Custom"
        var type: C64KeymapChoice = .symbolic
        var mappings: [String: UInt8] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(
                    in: CharacterSet(charactersIn: "[]")).lowercased()
                continue
            }
            let pair = line.split(
                separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if section == "meta" {
                if pair[0] == "name" { name = pair[1] }
                if pair[0] == "type" {
                    type = pair[1].lowercased() == "positional"
                        ? .positional : .symbolic
                }
            } else if section == "map" {
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                let code: UInt8?
                if value.lowercased().hasPrefix("0x") {
                    code = UInt8(value.dropFirst(2), radix: 16)
                } else {
                    code = UInt8(value)
                }
                if let code {
                    mappings[pair[0].trimmingCharacters(in: .whitespaces)]
                        = code
                }
            }
        }
        guard !mappings.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return C64KeymapFile(name: name, type: type, mappings: mappings)
    }
}
