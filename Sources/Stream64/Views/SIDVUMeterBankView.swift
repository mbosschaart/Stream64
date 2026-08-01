import SwiftUI

/// A dedicated, full-size meter bridge — one bold level meter per
/// channel, laid out in a single row like a real mixing console's meter
/// bank, unlike the thin 16pt-wide `SIDVUMeter` strip embedded in Mixer
/// Console. Adds a peak-hold notch (from `SIDVoiceChannel.peakLevel`) on
/// top of the live RMS-driven bar.
struct SIDVUMeterBankView: View {
    let channels: [SIDVoiceChannel]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(channels) { channel in
                SIDVUMeterBankStrip(channel: channel)
            }
        }
        .padding(14)
        .background(Color.black)
    }
}

private struct SIDVUMeterBankStrip: View {
    let channel: SIDVoiceChannel

    var body: some View {
        VStack(spacing: 6) {
            Text("SID \(channel.chipIndex + 1)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            Text("Ch \(channel.voiceIndex + 1)")
                .font(.callout).bold()
                .foregroundStyle(.white)
            SIDLargeVUMeter(level: channel.levelRMS, peak: channel.peakLevel)
                .frame(maxHeight: .infinity)
            Circle()
                .fill(channel.registers.gate ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
                .help(channel.registers.gate ? "Gate on" : "Gate off")
            Text("\(Int(channel.frequencyHz)) Hz")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .cornerRadius(8)
    }
}

/// A big vertical VU-style meter: a color-zoned bar (green/yellow/red)
/// driven by RMS level, plus a peak-hold notch that jumps to the recent
/// peak and decays slowly rather than tracking the level instantaneously.
struct SIDLargeVUMeter: View {
    let level: Float
    let peak: Float

    var body: some View {
        GeometryReader { geometry in
            // RMS of a typical bipolar voice signal sits well under 1.0
            // even at full envelope, so both are scaled up for a
            // readable meter — not a calibrated dB scale.
            let normalizedLevel = min(1, CGFloat(level) * 3.2)
            let normalizedPeak = min(1, CGFloat(peak) * 3.2)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [.green, .green, .yellow, .orange, .red],
                        startPoint: .bottom, endPoint: .top))
                    .frame(height: geometry.size.height * normalizedLevel)
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(height: 2)
                    .offset(y: -geometry.size.height * normalizedPeak)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.15)))
        }
    }
}
