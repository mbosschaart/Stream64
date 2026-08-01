import SwiftUI

/// Classic stereo-phase visualization: plots the real left channel against
/// the real right channel (both from `AudioReceiver`'s sample tap) instead
/// of either against time — a circle/line means mono-ish content, a wide
/// diagonal blob means strong stereo separation, and with the dual-SID
/// setup this can make each chip's contribution to the stereo field
/// visible if they're panned differently.
struct SIDLissajousView: View {
    let points: [(left: Float, right: Float)]
    var glow = false

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 2 - 10
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            var axes = Path()
            axes.move(to: CGPoint(x: center.x - scale, y: center.y))
            axes.addLine(to: CGPoint(x: center.x + scale, y: center.y))
            axes.move(to: CGPoint(x: center.x, y: center.y - scale))
            axes.addLine(to: CGPoint(x: center.x, y: center.y + scale))
            context.stroke(axes, with: .color(.white.opacity(0.12)), lineWidth: 0.5)

            guard points.count > 1 else { return }
            var path = Path()
            for (index, point) in points.enumerated() {
                // X = left, Y = -right (screen Y is flipped vs. audio convention).
                let x = center.x + CGFloat(point.left) * scale
                let y = center.y - CGFloat(point.right) * scale
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            if glow {
                var glowContext = context
                glowContext.addFilter(.blur(radius: 4))
                glowContext.stroke(path, with: .color(.green.opacity(0.3)), lineWidth: 2)
            }
            context.stroke(path, with: .color(.green), lineWidth: 1)
        }
        .background(Color.black)
    }
}
