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

    /// Real SID output rarely swings anywhere near full scale (±1), so at
    /// a plain 1:1 mapping the traced pattern only ever fills a small
    /// fraction of the available circle, leaving most of the window as
    /// unused black margin. Amplifying the point before mapping it to
    /// screen coordinates makes typical content actually use the space;
    /// `clamped` below caps the result afterwards so a genuinely loud,
    /// near-clipping signal still stays within the circle rather than
    /// drawing outside it.
    private static let gain: Float = 2.5

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
                let x = center.x + CGFloat(Self.clamped(point.left * Self.gain)) * scale
                let y = center.y - CGFloat(Self.clamped(point.right * Self.gain)) * scale
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

    private static func clamped(_ value: Float) -> Float {
        max(-1, min(1, value))
    }
}
