import SwiftUI

/// Shared "cheap 3D" perspective used by both waterfall-style spectrum
/// modes below: rather than a real 3D transform, each history row is
/// drawn with a 2D affine skew/scale/fade based on how far back it is
/// (`depth`: 0 = front/newest row, 1 = back/oldest row) — the same trick
/// classic real-time audio-analysis tools like sndpeek's spectrum
/// waterfall use to fake depth using only 2D drawing primitives.
private struct SIDWaterfallProjection {
    let baselineY: CGFloat
    let maxRise: CGFloat
    let horizontalSkew: CGFloat
    let widthShrink: CGFloat
    let peakHeight: CGFloat

    init(size: CGSize) {
        baselineY = size.height * 0.86
        maxRise = size.height * 0.58
        horizontalSkew = size.width * 0.14
        widthShrink = 0.22
        peakHeight = size.height * 0.46
    }

    func originX(depth: CGFloat) -> CGFloat { depth * horizontalSkew }
    func originY(depth: CGFloat) -> CGFloat { baselineY - depth * maxRise }

    func rowWidth(depth: CGFloat, canvasWidth: CGFloat) -> CGFloat {
        (canvasWidth - horizontalSkew) * (1 - depth * widthShrink)
    }

    func point(depth: CGFloat, t: CGFloat, value: Float, canvasWidth: CGFloat) -> CGPoint {
        CGPoint(
            x: originX(depth: depth) + t * rowWidth(depth: depth, canvasWidth: canvasWidth),
            y: originY(depth: depth) - CGFloat(value) * peakHeight)
    }
}

/// A scrolling 3D-look "waterfall" of the spectrum history — each row a
/// wireframe line, older rows drawn further back (higher, narrower,
/// dimmer) — the classic real-time look of tools like sndpeek's spectrum
/// display. Built from the same `SIDSpectrumAnalyzer` history the flat 2D
/// Spectrogram mode uses, just rendered differently.
struct SIDWaterfallSpectrumView: View {
    let history: [[Float]] // oldest first
    private static let maxRows = 36

    var body: some View {
        Canvas { context, size in
            let rows = Array(history.suffix(Self.maxRows))
            guard let barCount = rows.first?.count, barCount > 1, rows.count > 1 else { return }
            let projection = SIDWaterfallProjection(size: size)
            let rowCount = rows.count
            for (rowIndex, bars) in rows.enumerated() {
                // depth: 0 = newest/front row, 1 = oldest/back row.
                let depth = CGFloat(rowCount - 1 - rowIndex) / CGFloat(rowCount - 1)
                var path = Path()
                for (barIndex, value) in bars.enumerated() {
                    let t = CGFloat(barIndex) / CGFloat(barCount - 1)
                    let point = projection.point(depth: depth, t: t, value: value, canvasWidth: size.width)
                    if barIndex == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                let opacity = 0.15 + (1 - depth) * 0.85
                context.stroke(
                    path, with: .color(.green.opacity(opacity)),
                    lineWidth: depth < 0.05 ? 1.6 : 0.9)
            }
        }
        .background(Color.black)
    }
}

/// The same depth-based projection as the waterfall above, but drawn as
/// filled 3D-look bars in a blue → purple → pink → orange palette instead
/// of a green wireframe line — a bar-chart-style "waterfall."
struct SID3DBarSpectrumView: View {
    let history: [[Float]] // oldest first
    private static let maxRows = 14

    var body: some View {
        Canvas { context, size in
            let rows = Array(history.suffix(Self.maxRows))
            guard let barCount = rows.first?.count, barCount > 1, !rows.isEmpty else { return }
            let projection = SIDWaterfallProjection(size: size)
            let rowCount = rows.count
            // Draw oldest (back) first so nearer rows visually overlap
            // further ones — a cheap substitute for real z-occlusion.
            for (rowIndex, bars) in rows.enumerated() {
                let depth = CGFloat(rowCount - 1 - rowIndex) / CGFloat(max(rowCount - 1, 1))
                let rowWidth = projection.rowWidth(depth: depth, canvasWidth: size.width)
                let barWidth = rowWidth / CGFloat(barCount) * 0.72
                let baseY = projection.originY(depth: depth)
                let originX = projection.originX(depth: depth)
                for (barIndex, value) in bars.enumerated() {
                    let t = CGFloat(barIndex) / CGFloat(barCount - 1)
                    let x = originX + t * rowWidth
                    let topY = baseY - CGFloat(value) * projection.peakHeight
                    guard baseY - topY > 0.5 else { continue }
                    let rect = CGRect(x: x - barWidth / 2, y: topY, width: barWidth, height: baseY - topY)
                    context.fill(Path(rect), with: .color(Self.barColor(for: value, depth: depth)))
                }
            }
        }
        .background(Color.black)
    }

    /// Blue (quiet) → purple → pink → orange (loud), dimmed with depth so
    /// distant rows visually recede rather than competing with the front.
    private static func barColor(for value: Float, depth: CGFloat) -> Color {
        let v = Double(max(0, min(1, value)))
        let base: Color
        if v < 0.34 {
            let t = v / 0.34
            base = Color(red: 0.15 + t * 0.25, green: 0.05, blue: 0.55 + t * 0.35)
        } else if v < 0.67 {
            let t = (v - 0.34) / 0.33
            base = Color(red: 0.4 + t * 0.5, green: 0.05 + t * 0.1, blue: 0.9 - t * 0.3)
        } else {
            let t = (v - 0.67) / 0.33
            base = Color(red: 0.9 + t * 0.1, green: 0.15 + t * 0.55, blue: 0.6 - t * 0.6)
        }
        let fade = 0.35 + (1 - Double(depth)) * 0.65
        return base.opacity(fade)
    }
}
