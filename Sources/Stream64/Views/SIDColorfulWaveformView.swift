import SwiftUI

/// All voices' waveforms overlaid on one shared canvas, each in a
/// distinct vibrant color with a phosphor-glow-style bloom — a
/// style/showcase mode over the same data every other waveform-based
/// mode already has, closer to the colorful stock "audio equalizer" art
/// that inspired it than to a literal oscilloscope reading.
struct SIDColorfulWaveformView: View {
    let channels: [SIDVoiceChannel]
    /// Optional glow is evaluated directly in the fragment shader.
    var glow = false

    var body: some View {
        var input = SIDGenerativeUniforms()
        input.style.z = Float(max(3, (channels.map(\.chipIndex).max() ?? 0) * 3 + 3))
        input.style.w = glow ? 1 : 0
        return SIDPerformanceGPUView(scene: .waveform, input: input, channels: channels)
    }

}
