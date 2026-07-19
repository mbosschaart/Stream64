import SwiftUI

/// On-screen C64 keyboard. Keys send PETSCII codes straight to the
/// keyboard buffer, so it works even when no physical key mapping fits
/// (or keyboard capture is switched off).
struct OnScreenKeyboardView: View {
    let session: DeviceSession
    @State private var shifted = false

    private struct Key: Identifiable {
        let id = UUID()
        let label: String
        let code: UInt8
        var shiftedLabel: String?
        var shiftedCode: UInt8?
        var width: CGFloat = 1

        init(_ label: String, _ code: UInt8,
             shifted shiftedLabel: String? = nil, _ shiftedCode: UInt8? = nil,
             width: CGFloat = 1) {
            self.label = label
            self.code = code
            self.shiftedLabel = shiftedLabel
            self.shiftedCode = shiftedCode
            self.width = width
        }
    }

    // PETSCII: unshifted letters are 0x41-0x5A, shifted (graphics/upper) 0xC1-0xDA.
    private static func letter(_ c: Character) -> Key {
        let v = UInt8(c.asciiValue!)
        return Key(String(c), v, shifted: String(c), v + 0x80)
    }

    private var rows: [[Key]] {
        [
            [
                Key("←", 0x5F),
                Key("1", 0x31, shifted: "!", 0x21), Key("2", 0x32, shifted: "\"", 0x22),
                Key("3", 0x33, shifted: "#", 0x23), Key("4", 0x34, shifted: "$", 0x24),
                Key("5", 0x35, shifted: "%", 0x25), Key("6", 0x36, shifted: "&", 0x26),
                Key("7", 0x37, shifted: "'", 0x27), Key("8", 0x38, shifted: "(", 0x28),
                Key("9", 0x39, shifted: ")", 0x29), Key("0", 0x30),
                Key("+", 0x2B), Key("-", 0x2D), Key("£", 0x5C),
                Key("HOME", 0x13, shifted: "CLR", 0x93, width: 1.3),
                Key("DEL", 0x14, shifted: "INST", 0x94, width: 1.3),
            ],
            [
                Key("CTRL", 0x00, width: 1.5),
                Self.letter("Q"), Self.letter("W"), Self.letter("E"), Self.letter("R"),
                Self.letter("T"), Self.letter("Y"), Self.letter("U"), Self.letter("I"),
                Self.letter("O"), Self.letter("P"),
                Key("@", 0x40), Key("*", 0x2A), Key("↑", 0x5E),
                Key("RSTR", 0x00, width: 1.5),
            ],
            [
                Key("STOP", 0x03, width: 1.7),
                Self.letter("A"), Self.letter("S"), Self.letter("D"), Self.letter("F"),
                Self.letter("G"), Self.letter("H"), Self.letter("J"), Self.letter("K"),
                Self.letter("L"),
                Key(":", 0x3A, shifted: "[", 0x5B), Key(";", 0x3B, shifted: "]", 0x5D),
                Key("=", 0x3D),
                Key("RETURN", 0x0D, width: 2.2),
            ],
            [
                Key("SHIFT", 0x00, width: 2.2),
                Self.letter("Z"), Self.letter("X"), Self.letter("C"), Self.letter("V"),
                Self.letter("B"), Self.letter("N"), Self.letter("M"),
                Key(",", 0x2C, shifted: "<", 0x3C), Key(".", 0x2E, shifted: ">", 0x3E),
                Key("/", 0x2F, shifted: "?", 0x3F),
                Key("↕", 0x11, shifted: "↑", 0x91, width: 1.2),
                Key("↔", 0x1D, shifted: "←", 0x9D, width: 1.2),
            ],
            [
                Key("RVS", 0x12, shifted: "OFF", 0x92, width: 1.4),
                Key("SPACE", 0x20, width: 6),
                Key("F1", 0x85, shifted: "F2", 0x89, width: 1.2),
                Key("F3", 0x86, shifted: "F4", 0x8A, width: 1.2),
                Key("F5", 0x87, shifted: "F6", 0x8B, width: 1.2),
                Key("F7", 0x88, shifted: "F8", 0x8C, width: 1.2),
            ],
        ]
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row) { key in
                        keyButton(key)
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func keyButton(_ key: Key) -> some View {
        let isShiftKey = key.label == "SHIFT"
        let isDead = key.code == 0x00 && !isShiftKey // CTRL/RESTORE: no buffer code
        let label = (shifted ? key.shiftedLabel : nil) ?? key.label

        Button {
            if isShiftKey {
                shifted.toggle()
                return
            }
            let code = shifted ? (key.shiftedCode ?? key.code) : key.code
            if shifted { shifted = false }
            session.sendKeyCodes([code])
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .tint(isShiftKey && shifted ? .accentColor : nil)
        .disabled(isDead || !session.isConnected)
        .frame(width: 30 * key.width)
        .help(isDead ? "\(key.label) can't be sent through the keyboard buffer" : label)
    }
}
