import SwiftUI

/// Per-voice display of the *raw* Attack/Decay/Sustain/Release register
/// values (0-15 each) as bars, each labeled with its real millisecond
/// time from the datasheet-derived `SIDTiming` tables already used to
/// drive envelope synthesis. Distinct from the existing ADSR Envelope
/// mode, which plots the *resulting* envelope curve over time — this
/// shows the knob settings themselves, which nothing else displays.
struct SIDADSRKnobPanel: View {
    let channel: SIDVoiceChannel

    var body: some View {
        SIDPanelChrome(channel: channel) {
            HStack(spacing: 10) {
                SIDKnobBar(
                    label: "A", value: channel.registers.attack,
                    timeLabel: Self.timeLabel(milliseconds: SIDTiming.attackMilliseconds[channel.registers.attack]),
                    color: .yellow)
                SIDKnobBar(
                    label: "D", value: channel.registers.decay,
                    timeLabel: Self.timeLabel(milliseconds: SIDTiming.decayReleaseMilliseconds[channel.registers.decay]),
                    color: .orange)
                SIDKnobBar(
                    label: "S", value: channel.registers.sustain,
                    timeLabel: "\(channel.registers.sustain)/15", color: .green)
                SIDKnobBar(
                    label: "R", value: channel.registers.release,
                    timeLabel: Self.timeLabel(milliseconds: SIDTiming.decayReleaseMilliseconds[channel.registers.release]),
                    color: .red)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        } footer: {
            HStack {
                Text("Stage \(channel.envelopeStageLabel)")
                    .font(.system(.caption2, design: .monospaced))
                Spacer()
                Text("\(Int(channel.frequencyHz)) Hz · \(channel.noteName)")
                    .font(.system(.caption2, design: .monospaced))
            }
        }
    }

    private static func timeLabel(milliseconds: Double) -> String {
        milliseconds < 1000 ? "\(Int(milliseconds))ms" : String(format: "%.1fs", milliseconds / 1000)
    }
}

private struct SIDKnobBar: View {
    let label: String
    let value: Int // 0...15
    let timeLabel: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.85))
                        .frame(height: geometry.size.height * CGFloat(value) / 15)
                }
            }
            Text(label)
                .font(.caption2).bold()
                .foregroundStyle(.white)
            Text(timeLabel)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Per-voice gauge for the 12-bit pulse-width register (0-4095) — a duty
/// cycle bar plus a small preview of the resulting pulse shape at that
/// width. Surfaces PWM-sweep effects (a classic SID trick: continuously
/// changing pulse width for a "chorus"-like sound) that are invisible
/// everywhere else, since every other mode's waveform trace only shows
/// the *result*, not the underlying duty-cycle value.
struct SIDPulseWidthPanel: View {
    let channel: SIDVoiceChannel

    var body: some View {
        SIDPanelChrome(channel: channel) {
            SIDPulseWidthGauge(pulseWidth: channel.registers.pulseWidth)
        } footer: {
            HStack {
                Text("PW \(channel.registers.pulseWidth)/4095")
                    .font(.system(.caption2, design: .monospaced))
                Spacer()
                Text(String(format: "%.1f%% duty", dutyPercent))
                    .font(.system(.caption2, design: .monospaced))
            }
        }
    }

    private var dutyPercent: Double {
        Double(channel.registers.pulseWidth) / 4095 * 100
    }
}

private struct SIDPulseWidthGauge: View {
    let pulseWidth: UInt16 // 0...4095

    var body: some View {
        Canvas { context, size in
            let duty = CGFloat(pulseWidth) / 4095
            let barRect = CGRect(x: 4, y: size.height * 0.12, width: size.width - 8, height: size.height * 0.22)
            context.stroke(
                Path(roundedRect: barRect, cornerRadius: 3), with: .color(.white.opacity(0.25)), lineWidth: 1)
            let fillRect = CGRect(
                x: barRect.minX, y: barRect.minY, width: max(1, barRect.width * duty), height: barRect.height)
            context.fill(Path(roundedRect: fillRect, cornerRadius: 3), with: .color(.cyan))

            // A small preview of the resulting pulse wave at this duty
            // cycle, over a few periods.
            let waveY = size.height * 0.68
            let waveHalfHeight = size.height * 0.18
            let periods = 3
            let stepsPerPeriod = 60
            var path = Path()
            for i in 0...(periods * stepsPerPeriod) {
                let t = Double(i) / Double(stepsPerPeriod)
                let phase = t - t.rounded(.down)
                let high = phase < Double(duty)
                let x = size.width * CGFloat(i) / CGFloat(periods * stepsPerPeriod)
                let y = waveY + (high ? -waveHalfHeight : waveHalfHeight)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(.cyan.opacity(0.85)), lineWidth: 1.3)
        }
        .background(Color.black)
    }
}
