import Foundation

/// Maps PETSCII byte codes outside the plain-ASCII range to the Unicode
/// glyph they should render as, for `VT100Screen`'s decode of the
/// Ultimate's Telnet ("Ultimate Menu") output.
///
/// The printable ASCII range (0x20-0x7E) is passed straight through
/// unchanged — confirmed against a real device that the Ultimate's
/// Telnet UI sends genuine mixed-case ASCII/VT100 text for its labels
/// (e.g. "Ultimate", "Free"), not the C64's internal PETSCII *screen*
/// encoding, where that same byte range means graphics/uppercase-only.
/// An earlier version of this decoder assumed the latter and
/// reinterpreted ordinary lowercase letters as PETSCII graphics (e.g.
/// 'a' → "♠"), which badly regressed normal text — see `HANDOVER.md`
/// §14 for the full story. Only bytes with **no** legitimate meaning as
/// plain ASCII (0x80-0xFF) still get PETSCII-style treatment — control
/// codes (0x80-0x9F, mirroring the printable range's own control codes
/// at 0x00-0x1F) and decorative block/line/card-suit graphics
/// (0xA0-0xFF) — since the on-device menu's borders/meters do appear to
/// use bytes in that range, and reinterpreting them can never break
/// legitimate ASCII text (those bytes would never validly appear as
/// such in the first place).
///
/// A handful of PETSCII's rarer block/mosaic graphics (Unicode's
/// "Symbols for Legacy Computing" block, only added in Unicode 13.0)
/// don't reliably have glyphs in common system fonts yet; those are
/// approximated with plain shade blocks (░/▒) rather than left
/// unmapped.
enum PETSCIIGlyph {
    static func character(for byte: UInt8) -> Character {
        switch byte {
        case 0x20...0x7E:
            return Character(UnicodeScalar(byte))
        case 0xA0...0xBF:
            return blockGraphic(byte)
        case 0xC0...0xDF:
            return highGraphic(byte)
        case 0xE0...0xFF:
            return blockGraphic(byte - 0x40)
        default:
            // 0x7F (DEL) and the control-code ranges (0x00-0x1F,
            // 0x80-0x9F) — VT100Screen intercepts control codes before
            // they ever reach here; DEL has no glyph of its own.
            return " "
        }
    }

    private static func highGraphic(_ byte: UInt8) -> Character {
        switch byte {
        case 0xC0: return "─"
        case 0xC1: return "♠"
        case 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8: return "░"
        case 0xC9: return "╮"
        case 0xCA: return "╰"
        case 0xCB: return "╯"
        case 0xCC: return "░"
        case 0xCD: return "╲"
        case 0xCE: return "╱"
        case 0xCF: return "░"
        case 0xD0: return "░"
        case 0xD1: return "•"
        case 0xD2: return "░"
        case 0xD3: return "♥"
        case 0xD4: return "░"
        case 0xD5: return "╭"
        case 0xD6: return "╳"
        case 0xD7: return "○"
        case 0xD8: return "♣"
        case 0xD9: return "░"
        case 0xDA: return "♦"
        case 0xDB: return "┼"
        case 0xDC: return "▒"
        case 0xDD: return "│"
        case 0xDE: return "π"
        case 0xDF: return "◥"
        default: return "?"
        }
    }

    private static func blockGraphic(_ byte: UInt8) -> Character {
        switch byte {
        case 0xA0: return " "
        case 0xA1: return "▌"
        case 0xA2: return "▄"
        case 0xA3: return "▔"
        case 0xA4: return "▁"
        case 0xA5: return "▏"
        case 0xA6: return "▒"
        case 0xA7: return "▕"
        case 0xA8: return "▒"
        case 0xA9: return "◤"
        case 0xAA: return "▒"
        case 0xAB: return "├"
        case 0xAC: return "▗"
        case 0xAD: return "└"
        case 0xAE: return "┐"
        case 0xAF: return "▂"
        case 0xB0: return "┌"
        case 0xB1: return "┴"
        case 0xB2: return "┬"
        case 0xB3: return "┤"
        case 0xB4: return "▎"
        case 0xB5: return "▍"
        case 0xB6: return "▒"
        case 0xB7: return "▔"
        case 0xB8: return "▄"
        case 0xB9: return "▃"
        case 0xBA: return "░"
        case 0xBB: return "▖"
        case 0xBC: return "▝"
        case 0xBD: return "┘"
        case 0xBE: return "▘"
        case 0xBF: return "▚"
        default: return "?"
        }
    }
}

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
