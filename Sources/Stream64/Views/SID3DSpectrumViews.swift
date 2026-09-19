import SwiftUI

/// A scrolling 3D-look "waterfall" of the spectrum history — each row a
/// wireframe line, older rows drawn further back (higher, narrower,
/// dimmer) — the classic real-time look of tools like sndpeek's spectrum
/// display. Built from the same `SIDSpectrumAnalyzer` history the flat 2D
/// Spectrogram mode uses, just rendered differently.
struct SIDWaterfallSpectrumView: View {
    let history: [[Float]] // oldest first

    var body: some View {
        SIDPerformanceGPUView(scene: .waterfall, history: history)
    }
}

/// The same depth-based projection as the waterfall above, but drawn as
/// filled 3D-look bars in a blue → purple → pink → orange palette instead
/// of a green wireframe line — a bar-chart-style "waterfall."
struct SID3DBarSpectrumView: View {
    let history: [[Float]] // oldest first

    var body: some View {
        SIDPerformanceGPUView(scene: .barField, history: history)
    }

}
