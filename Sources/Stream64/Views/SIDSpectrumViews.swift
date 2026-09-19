import AppKit
import SwiftUI

/// Classic FFT bar-graph EQ display off the real post-mix Ultimate audio
/// (via `AudioReceiver`'s sample tap + `SIDSpectrumAnalyzer`) — reflects
/// actual SID output, unlike the register-driven modes which only
/// approximate what each voice's oscillator should sound like.
struct SIDSpectrumView: View {
    let bars: [Float]
    var glow = false

    var body: some View {
        var input = SIDGenerativeUniforms()
        input.style.w = glow ? 1 : 0
        return SIDPerformanceGPUView(scene: .spectrum, input: input, history: [bars])
    }

}

/// Scrolling FFT history drawn directly by Metal from numeric spectrum data.
struct SIDSpectrogramView: View {
    /// Oldest-first columns of bar spectra (each the same shape
    /// `SIDSpectrumAnalyzer` produces).
    let history: [[Float]]
    /// Reduce presentation rate while the live CRT path is under pressure.
    var videoGPUBehind: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            SIDPianoKeyGutter()
                .frame(width: 34)
                .drawingGroup(opaque: true, colorMode: .linear)
            SIDPerformanceGPUView(scene: .spectrogram, history: history, underPressure: videoGPUBehind)
        }
        .background(Color.black)
    }
}

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
