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
        VStack(alignment: .leading, spacing: 8) {
            Text("SID \(channel.chipIndex + 1) · Channel \(channel.voiceIndex + 1)")
                .font(.callout).bold()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 10
            ) {
                ForEach(bits, id: \.label) { bit in
                    SIDControlBitLED(label: bit.label, isOn: bit.isOn, color: bit.color)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .cornerRadius(6)
    }
}

private struct SIDControlBitLED: View {
    let label: String
    let isOn: Bool
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(isOn ? color : Color.white.opacity(0.08))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2)))
                .frame(width: 16, height: 16)
                .shadow(color: isOn ? color.opacity(0.7) : .clear, radius: 4)
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(isOn ? 0.9 : 0.4))
        }
        .frame(maxWidth: .infinity)
    }
}
