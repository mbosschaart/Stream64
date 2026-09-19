import SwiftUI

/// Per-voice LED-style indicator grid for all 8 control-register bits —
/// Gate/Sync/Ring/Test and the 4 waveform-select bits (Triangle/
/// Sawtooth/Pulse/Noise) — at a glance. Simpler and broader than the
/// removed Wiring Diagram mode, which only visualized Sync/Ring.
struct SIDControlBitsPanel: View {
    let channel: SIDVoiceChannel

    private var bits: [(label: String, isOn: Bool, color: Color)] {
        [
            ("GATE", channel.registers.gate, .green),
            ("SYNC", channel.registers.syncEnabled, .yellow),
            ("RING", channel.registers.ringModEnabled, .purple),
            ("TEST", channel.registers.test, .red),
            ("TRI", channel.registers.triangleEnabled, .cyan),
            ("SAW", channel.registers.sawtoothEnabled, .cyan),
            ("PULSE", channel.registers.pulseEnabled, .cyan),
            ("NOISE", channel.registers.noiseEnabled, .cyan),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = SIDPanelSizing.scale(in: geometry.size, reference: CGSize(width: 240, height: 220))
            VStack(alignment: .leading, spacing: 12 * scale) {
                Text("SID \(channel.chipIndex + 1) · Channel \(channel.voiceIndex + 1)")
                    .font(.system(size: 14 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                VStack(spacing: 12 * scale) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 6 * scale) {
                            ForEach(0..<4, id: \.self) { column in
                                let bit = bits[row * 4 + column]
                                SIDControlBitLED(label: bit.label, isOn: bit.isOn,
                                                 color: bit.color, scale: scale)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
            .padding(10 * scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(white: 0.08))
        .cornerRadius(6)
    }
}

private struct SIDControlBitLED: View {
    let label: String
    let isOn: Bool
    let color: Color
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 7 * scale) {
            Circle()
                .fill(isOn ? color : Color.white.opacity(0.08))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2)))
                .frame(width: 30 * scale, height: 30 * scale)
                .shadow(color: isOn ? color.opacity(0.7) : .clear, radius: 4 * scale)
            Text(label)
                .font(.system(size: 9 * scale, design: .monospaced))
                .foregroundStyle(.white.opacity(isOn ? 0.9 : 0.4))
        }
        .frame(maxWidth: .infinity)
    }
}
