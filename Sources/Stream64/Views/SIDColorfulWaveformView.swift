import SwiftUI

/// All voices' waveforms overlaid on one shared canvas, each in a
/// distinct vibrant color with a phosphor-glow-style bloom — a
/// style/showcase mode over the same data every other waveform-based
/// mode already has, closer to the colorful stock "audio equalizer" art
/// that inspired it than to a literal oscilloscope reading.
struct SIDColorfulWaveformView: View {
    let channels: [SIDVoiceChannel]
    /// Unlike every other mode's phosphor-glow overlay (off by default,
    /// toggled via the window's context menu), this used to run its 3
    /// Core Image blur passes per channel unconditionally — up to 18
    /// blurs/frame with a full 6-voice dual-SID setup, easily the most
    /// expensive single Canvas in the app. Now matches the other modes:
    /// optional, off by default, bound to `phosphorGlowEnabled`.
    var glow = false

    private static let palette: [Color] = [
        Color(red: 1.0, green: 0.25, blue: 0.55), // pink
        Color(red: 0.25, green: 0.85, blue: 1.0), // cyan
        Color(red: 1.0, green: 0.75, blue: 0.15), // amber
        Color(red: 0.55, green: 0.35, blue: 1.0), // violet
        Color(red: 0.25, green: 1.0, blue: 0.55), // green
        Color(red: 1.0, green: 0.45, blue: 0.15), // orange
    ]

    var body: some View {
        Canvas { context, size in
            for (index, channel) in channels.enumerated() {
                let color = Self.palette[index % Self.palette.count]
                let samples = channel.orderedSamples
                guard samples.count > 1 else { continue }
                let path = Self.path(for: samples, size: size)
                if glow {
                    for (radius, opacity) in [(10.0, 0.10), (5.0, 0.18), (2.0, 0.30)] {
                        var glowContext = context
                        glowContext.addFilter(.blur(radius: radius))
                        glowContext.stroke(path, with: .color(color.opacity(opacity)), lineWidth: 3)
                    }
                }
                context.stroke(path, with: .color(color), lineWidth: 1.6)
            }
        }
        .background(Color.black)
    }

    private static func path(for samples: [Float], size: CGSize) -> Path {
        let stepX = size.width / CGFloat(samples.count - 1)
        let amplitude = size.height / 2 - 6
        var path = Path()
        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * stepX
            let y = size.height / 2 - CGFloat(sample) * amplitude
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
