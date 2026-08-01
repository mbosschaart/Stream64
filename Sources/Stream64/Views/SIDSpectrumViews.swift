import SwiftUI

/// Classic FFT bar-graph EQ display off the real post-mix Ultimate audio
/// (via `AudioReceiver`'s sample tap + `SIDSpectrumAnalyzer`) — reflects
/// actual SID output, unlike the register-driven modes which only
/// approximate what each voice's oscillator should sound like.
struct SIDSpectrumView: View {
    let bars: [Float]
    var glow = false

    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let barWidth = size.width / CGFloat(bars.count)
            for (index, value) in bars.enumerated() {
                let barHeight = CGFloat(value) * size.height
                let rect = CGRect(
                    x: CGFloat(index) * barWidth + 1, y: size.height - barHeight,
                    width: max(1, barWidth - 2), height: barHeight)
                let color = Self.color(forValue: value)
                if glow, barHeight > 1 {
                    var glowContext = context
                    glowContext.addFilter(.blur(radius: 4))
                    glowContext.fill(Path(rect), with: .color(color.opacity(0.35)))
                }
                context.fill(Path(rect), with: .color(color))
            }
        }
        .background(Color.black)
    }

    private static func color(forValue value: Float) -> Color {
        if value > 0.8 { return .red }
        if value > 0.55 { return .yellow }
        return .green
    }
}

/// Scrolling time-vs-frequency heatmap built the same way `MemoryMapView`
/// builds its address heatmap (except drawn directly with `Canvas` rects
/// here, since the column/row counts are small enough — 160×48 — that a
/// raw-pixel-buffer `CGImage` isn't needed for performance the way it is
/// for `MemoryMapView`'s 65536-pixel grid). A piano-key gutter down the
/// left side (mirroring the note-aligned spectrogram look common in
/// pitch-analysis tools) labels the log-frequency axis by note name
/// instead of raw Hz, since that reads far more naturally against music.
struct SIDSpectrogramView: View {
    /// Oldest-first columns of bar spectra (each the same shape
    /// `SIDSpectrumAnalyzer` produces).
    let history: [[Float]]

    var body: some View {
        HStack(spacing: 0) {
            SIDPianoKeyGutter()
                .frame(width: 34)
            Canvas { context, size in
                guard let barCount = history.first?.count, barCount > 0, !history.isEmpty else { return }
                let columnWidth = size.width / CGFloat(history.count)
                let rowHeight = size.height / CGFloat(barCount)
                for (columnIndex, bars) in history.enumerated() {
                    let x = CGFloat(columnIndex) * columnWidth
                    for (rowIndex, value) in bars.enumerated() {
                        // Row 0 (lowest frequency) drawn at the bottom —
                        // bars are already log-frequency-spaced by
                        // `SIDSpectrumAnalyzer`, matching evenly-spaced
                        // rows here to the piano-key gutter's log mapping.
                        let y = size.height - CGFloat(rowIndex + 1) * rowHeight
                        let rect = CGRect(x: x, y: y, width: columnWidth + 0.5, height: rowHeight + 0.5)
                        context.fill(Path(rect), with: .color(Self.fireColor(for: value)))
                    }
                }
            }
            .background(Color.black)
        }
        .background(Color.black)
    }

    /// Black → purple → red → orange → yellow "fire" heat ramp.
    private static func fireColor(for value: Float) -> Color {
        let v = Double(max(0, min(1, value)))
        if v < 0.25 {
            let t = v / 0.25
            return Color(red: t * 0.3, green: 0, blue: t * 0.4)
        }
        if v < 0.5 {
            let t = (v - 0.25) / 0.25
            return Color(red: 0.3 + t * 0.65, green: 0, blue: 0.4 - t * 0.35)
        }
        if v < 0.75 {
            let t = (v - 0.5) / 0.25
            return Color(red: 0.95, green: t * 0.55, blue: max(0, 0.05 - t * 0.05))
        }
        let t = (v - 0.75) / 0.25
        return Color(red: 1, green: 0.55 + t * 0.4, blue: t * 0.15)
    }
}

/// Note-name gridlines for the Spectrogram's log-frequency vertical axis
/// — every C from the lowest frequency the analyzer bins to just under
/// its Nyquist limit, using the exact same log mapping
/// `SIDSpectrumAnalyzer` uses to bucket bars, so gridlines land exactly
/// on the row boundaries they're labeling.
private struct SIDPianoKeyGutter: View {
    var body: some View {
        Canvas { context, size in
            for midi in stride(from: 12, through: 120, by: 12) {
                let frequency = 440.0 * pow(2.0, (Double(midi) - 69) / 12)
                let nyquist = SIDSpectrumAnalyzer.defaultSampleRate / 2
                guard frequency >= SIDSpectrumAnalyzer.minFrequency, frequency <= nyquist else { continue }
                let y = Self.y(forFrequency: frequency, nyquist: nyquist, size: size)
                var tick = Path()
                tick.move(to: CGPoint(x: size.width - 5, y: y))
                tick.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(tick, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
                context.draw(
                    Text("C\(midi / 12 - 1)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6)),
                    at: CGPoint(x: size.width - 8, y: y), anchor: .trailing)
            }
        }
        .background(Color.black)
    }

    private static func y(forFrequency frequency: Double, nyquist: Double, size: CGSize) -> CGFloat {
        let t = log(frequency / SIDSpectrumAnalyzer.minFrequency) / log(nyquist / SIDSpectrumAnalyzer.minFrequency)
        return size.height * (1 - CGFloat(max(0, min(1, t))))
    }
}
