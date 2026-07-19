import Foundation

/// ASCII/Unicode → PETSCII conversion for keyboard-buffer injection.
enum PETSCII {
    /// Control codes that are meaningful to pass through unchanged.
    static let controlCodes: Set<UInt8> = [
        0x03, // RUN/STOP
        0x05, 0x1C, 0x1E, 0x1F, // white, red, green, blue
        0x0D, // RETURN
        0x11, 0x91, // cursor down / up
        0x12, 0x92, // reverse on / off
        0x13, 0x93, // home / clear
        0x14, 0x94, // delete / insert
        0x1D, 0x9D, // cursor right / left
        0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, // F1-F8
        0x81, 0x90, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9E, 0x9F, // colors
        0x0E, 0x8E, // charset lower / upper
    ]

    /// Encode text as PETSCII codes. Unmappable characters are dropped.
    static func encode(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x0A, 0x0D: out.append(0x0D)                       // newline → RETURN
            case 0x61...0x7A: out.append(UInt8(v - 0x20))           // a-z → PETSCII 0x41-0x5A
            case 0x41...0x5A: out.append(UInt8(v + 0x80))           // A-Z → shifted 0xC1-0xDA
            case 0x20...0x40, 0x5B, 0x5D: out.append(UInt8(v))      // space..@, digits, [, ]
            case 0xA3: out.append(0x5C)                             // £
            case 0x5E: out.append(0x5E)                             // ^ → up arrow
            case 0x5F: out.append(0x5F)                             // _ → left arrow
            default:
                if v <= 0xFF, controlCodes.contains(UInt8(v)) {
                    out.append(UInt8(v))
                }
            }
        }
        return out
    }
}
