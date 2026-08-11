import SwiftUI

/// Per-voice piano keyboard that lights and "presses" the key matching
/// the tone currently playing on that SID channel. Uses live gate +
/// frequency (not the Piano Roll's scrolling history), so a held note
/// stays down for as long as the voice is gated.
struct SIDPianoKeyboardPanel: View {
    let channel: SIDVoiceChannel

    private static let colors: [Color] = [
        .green, .orange, .cyan, .pink, .yellow, .purple,
    ]

    private var accent: Color {
        Self.colors[channel.id % Self.colors.count]
    }

    /// Active MIDI note while the gate is on and the frequency is usable.
    private var pressedMidi: Int? {
        guard channel.registers.gate else { return nil }
        return channel.midiNoteNumber
    }

    var body: some View {
        SIDPanelChrome(channel: channel) {
            SIDPianoKeyboardCanvas(
                pressedMidi: pressedMidi,
                accent: accent)
        } footer: {
            HStack {
                Text(channel.waveformLabel)
                    .font(.system(.caption2, design: .monospaced))
                Spacer()
                Text("\(Int(channel.frequencyHz)) Hz · \(channel.noteName)")
                    .font(.system(.caption2, design: .monospaced))
            }
        }
    }
}

/// Fixed piano span for the per-voice keyboard — pulled out so key
/// geometry is unit-testable without SwiftUI. The range never slides with
/// the playing note; only which key is lit changes.
enum SIDPianoKeyboardLayout {
    /// Inclusive MIDI span drawn for every panel (C1…C7) — same pitch
    /// window as Piano Roll, so high SID leads don't fall off the top.
    static let minMidi = 24
    static let maxMidi = 96
    static let range: ClosedRange<Int> = minMidi...maxMidi

    static func isBlackKey(_ midi: Int) -> Bool {
        switch midi % 12 {
        case 1, 3, 6, 8, 10: return true
        default: return false
        }
    }

    /// White keys in `range`, left-to-right.
    static func whiteKeys(in range: ClosedRange<Int> = range) -> [Int] {
        range.filter { !isBlackKey($0) }
    }

    /// Black keys in `range` that sit between two white keys of the span.
    static func blackKeys(in range: ClosedRange<Int> = range) -> [Int] {
        range.filter { isBlackKey($0) }
    }
}

private struct SIDPianoKeyboardCanvas: View {
    let pressedMidi: Int?
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let whites = SIDPianoKeyboardLayout.whiteKeys()
            let blacks = SIDPianoKeyboardLayout.blackKeys()
            guard !whites.isEmpty, size.width > 1, size.height > 1 else { return }

            let whiteWidth = size.width / CGFloat(whites.count)
            let whiteHeight = size.height
            let blackWidth = whiteWidth * 0.58
            let blackHeight = whiteHeight * 0.58
            let pressInset: CGFloat = 1.5

            // Map MIDI → white-key index for positioning black keys between
            // their surrounding whites.
            var whiteIndexByMidi: [Int: Int] = [:]
            for (index, midi) in whites.enumerated() {
                whiteIndexByMidi[midi] = index
            }

            for (index, midi) in whites.enumerated() {
                let isPressed = midi == pressedMidi
                var rect = CGRect(
                    x: CGFloat(index) * whiteWidth,
                    y: 0,
                    width: whiteWidth,
                    height: whiteHeight)
                if isPressed {
                    rect = rect.insetBy(dx: pressInset, dy: pressInset)
                    rect.origin.y += 2
                    rect.size.height -= 2
                }
                let fill: Color = isPressed
                    ? accent.opacity(0.85)
                    : Color(white: 0.92)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(fill))
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(Color.black.opacity(0.35)),
                    lineWidth: 0.8)
                if isPressed {
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(accent.opacity(0.25)))
                }
            }

            for midi in blacks {
                // Sit the black key between the white key below it and the
                // next white — e.g. C# between C and D.
                let below = midi - 1
                guard let belowIndex = whiteIndexByMidi[below]
                        ?? whiteIndexByMidi[midi - 2]
                else { continue }
                let centerX = CGFloat(belowIndex + 1) * whiteWidth
                let isPressed = midi == pressedMidi
                var rect = CGRect(
                    x: centerX - blackWidth / 2,
                    y: 0,
                    width: blackWidth,
                    height: blackHeight)
                if isPressed {
                    rect = rect.insetBy(dx: 0.5, dy: 0)
                    rect.origin.y += 2
                    rect.size.height -= 2
                }
                let fill: Color = isPressed ? accent : Color(white: 0.12)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .color(fill))
                if isPressed {
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(.white.opacity(0.55)),
                        lineWidth: 1)
                }
            }
        }
        .padding(2)
    }
}
