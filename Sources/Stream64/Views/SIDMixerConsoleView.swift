import SwiftUI

/// A denser per-channel strip than the plain Oscilloscope panel: mini
/// waveform + a VU-style level meter + ADSR-stage badge + note/frequency,
/// laid out like a real mixing-desk channel strip. Uses the same
/// `SIDChannelGrid` as Oscilloscope/ADSR Envelope.
struct SIDMixerStripPanel: View {
    let channel: SIDVoiceChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SID \(channel.chipIndex + 1) · Channel \(channel.voiceIndex + 1)")
                    .font(.callout).bold()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Circle()
                    .fill(channel.registers.gate ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .help(channel.registers.gate ? "Gate on" : "Gate off")
            }
            HStack(spacing: 6) {
                WaveformTrace(samples: channel.orderedSamples, color: .green, bipolar: true)
                    .background(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.white.opacity(0.15)))
                SIDVUMeter(level: channel.levelRMS)
                    .frame(width: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(channel.waveformLabel)
                    .font(.system(.caption2, design: .monospaced))
                Text(channel.envelopeStageLabel)
                    .font(.system(.caption2, design: .monospaced)).bold()
                    .foregroundStyle(stageColor)
                Spacer()
                Text("\(Int(channel.frequencyHz)) Hz · \(channel.noteName)")
                    .font(.system(.caption2, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .cornerRadius(6)
    }

    private var stageColor: Color {
        switch channel.envelopeStageLabel {
        case "A": return .yellow
        case "D": return .orange
        case "S": return .green
        case "R": return .red
        default: return .white
        }
    }
}

/// A simple vertical level meter (bottom-up fill), scaled up from RMS
/// since a typical SID voice's RMS sits well under 1.0 even at full
/// envelope — not a calibrated dB meter, just a readable at-a-glance bar.
struct SIDVUMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            let normalized = min(1, CGFloat(level) * 3.2)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [.green, .green, .yellow, .red],
                        startPoint: .bottom, endPoint: .top))
                    .frame(height: geometry.size.height * normalized)
            }
        }
    }
}
