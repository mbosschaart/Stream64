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
/// for `MemoryMapView`'s 65536-pixel grid).
struct SIDSpectrogramView: View {
    /// Oldest-first columns of bar spectra (each the same shape
    /// `SIDSpectrumAnalyzer` produces).
    let history: [[Float]]

    var body: some View {
        Canvas { context, size in
            guard let barCount = history.first?.count, barCount > 0, !history.isEmpty else { return }
            let columnWidth = size.width / CGFloat(history.count)
            let rowHeight = size.height / CGFloat(barCount)
            for (columnIndex, bars) in history.enumerated() {
                let x = CGFloat(columnIndex) * columnWidth
                for (rowIndex, value) in bars.enumerated() {
                    // Row 0 (lowest frequency) drawn at the bottom.
                    let y = size.height - CGFloat(rowIndex + 1) * rowHeight
                    let rect = CGRect(x: x, y: y, width: columnWidth + 0.5, height: rowHeight + 0.5)
                    context.fill(Path(rect), with: .color(Self.heatColor(for: value)))
                }
            }
        }
        .background(Color.black)
    }

    /// Black → blue → green → yellow → red heat ramp.
    private static func heatColor(for value: Float) -> Color {
        let v = Double(max(0, min(1, value)))
        if v < 0.25 { return Color(red: 0, green: 0, blue: v * 4) }
        if v < 0.5 { return Color(red: 0, green: (v - 0.25) * 4, blue: 1 - (v - 0.25) * 4) }
        if v < 0.75 { return Color(red: (v - 0.5) * 4, green: 1, blue: 0) }
        return Color(red: 1, green: max(0, 1 - (v - 0.75) * 4), blue: 0)
    }
}
