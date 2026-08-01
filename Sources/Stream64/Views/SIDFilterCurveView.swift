import SwiftUI

/// A per-chip approximate frequency-response curve drawn from the newly
/// decoded global filter registers (`SIDFilterRegisters`) — cutoff,
/// resonance, LP/BP/HP mode, which voices are routed through it. The
/// curve is a simplified resonant-filter magnitude formula parametrized
/// by cutoff/resonance/mode, not a reproduction of the SID's real analog
/// filter response (which is chip-specific — 6581 vs. 8580 — and not
/// officially published).
struct SIDFilterCurveView: View {
    let channels: [SIDVoiceChannel]
    let filterStates: [SIDFilterRegisters]

    var body: some View {
        GeometryReader { geometry in
            let rows = max(filterStates.count, 1)
            let rowHeight = geometry.size.height / CGFloat(rows)
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    SIDChipFilterPanel(
                        chipIndex: row,
                        filter: filterStates.indices.contains(row) ? filterStates[row] : SIDFilterRegisters())
                        .frame(height: rowHeight)
                }
            }
        }
        .background(Color.black)
    }
}

private struct SIDChipFilterPanel: View {
    let chipIndex: Int
    let filter: SIDFilterRegisters

    private static let minFrequency = 20.0
    private static let maxFrequency = 20000.0
    private static let curveSamples = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SID \(chipIndex + 1) Filter")
                    .font(.callout).bold()
                    .foregroundStyle(.white)
                Spacer()
                Text(modeLabel)
                    .font(.caption).bold()
                    .foregroundStyle(.cyan)
            }
            Canvas { context, size in
                drawCurve(context: context, size: size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.15)))
            HStack {
                Text(
                    "Cutoff \(Int(SIDFilterRegisters.approximateCutoffHz(filter.cutoffValue))) Hz"
                        + " · Res \(filter.resonance)/15 · Vol \(filter.volume)/15"
                )
                .font(.system(.caption2, design: .monospaced))
                Spacer()
                Text(routedLabel)
                    .font(.system(.caption2, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }

    private var modeLabel: String {
        var parts: [String] = []
        if filter.lowPassEnabled { parts.append("LP") }
        if filter.bandPassEnabled { parts.append("BP") }
        if filter.highPassEnabled { parts.append("HP") }
        return parts.isEmpty ? "Off" : parts.joined(separator: "+")
    }

    private var routedLabel: String {
        let routed = (0..<3).filter { filter.voiceRouted($0) }.map { "Ch\($0 + 1)" }
        var label = routed.isEmpty ? "No voices routed" : "Routed: " + routed.joined(separator: ", ")
        if filter.voice3Disconnected { label += " · Ch3 muted" }
        return label
    }

    private func drawCurve(context: GraphicsContext, size: CGSize) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 1))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
        context.stroke(baseline, with: .color(.white.opacity(0.15)), lineWidth: 0.5)

        let cutoffHz = SIDFilterRegisters.approximateCutoffHz(filter.cutoffValue)
        var path = Path()
        for sample in 0..<Self.curveSamples {
            let t = Double(sample) / Double(Self.curveSamples - 1)
            let freq = Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, t)
            let magnitude = Self.magnitude(
                atFrequency: freq, cutoff: cutoffHz, resonance: filter.resonance,
                lowPass: filter.lowPassEnabled, bandPass: filter.bandPassEnabled,
                highPass: filter.highPassEnabled)
            let x = CGFloat(t) * size.width
            let y = size.height - CGFloat(min(1.5, magnitude) / 1.5) * (size.height - 4) - 2
            if sample == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(.cyan), lineWidth: 1.5)

        let cutoffT = log(max(cutoffHz, Self.minFrequency) / Self.minFrequency)
            / log(Self.maxFrequency / Self.minFrequency)
        if cutoffT >= 0, cutoffT <= 1 {
            var marker = Path()
            let x = CGFloat(cutoffT) * size.width
            marker.move(to: CGPoint(x: x, y: 0))
            marker.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                marker, with: .color(.white.opacity(0.3)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    /// A simplified 2-pole resonant-filter magnitude formula (not the real
    /// SID's transfer function) — enough to draw a recognizable
    /// lowpass/highpass/bandpass shape with a resonance peak at cutoff.
    private static func magnitude(
        atFrequency f: Double, cutoff fc: Double, resonance: Int,
        lowPass: Bool, bandPass: Bool, highPass: Bool
    ) -> Double {
        guard fc > 0 else { return 0 }
        let q = 0.5 + Double(resonance) / 15.0 * 8.0
        let ratio = f / fc
        let denom = max(1e-6, sqrt(pow(1 - ratio * ratio, 2) + pow(ratio / q, 2)))
        let lowPassMagnitude = 1 / denom
        let highPassMagnitude = (ratio * ratio) / denom
        let bandPassMagnitude = (ratio / q) / denom
        var combined = 0.0
        var count = 0
        if lowPass { combined += lowPassMagnitude; count += 1 }
        if highPass { combined += highPassMagnitude; count += 1 }
        if bandPass { combined += bandPassMagnitude; count += 1 }
        return count > 0 ? combined / Double(count) : 0
    }
}
