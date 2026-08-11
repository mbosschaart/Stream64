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

/// Scrolling time-vs-frequency heatmap. FFT analysis stays on the CPU
/// (`SIDSpectrumAnalyzer` / vDSP); drawing uses a reusable RGBA column
/// texture on an AppKit layer — the same approach as `MemoryHeatmapNSView`
/// — instead of thousands of SwiftUI `Canvas` fills per frame.
struct SIDSpectrogramView: View {
    /// Oldest-first columns of bar spectra (each the same shape
    /// `SIDSpectrumAnalyzer` produces).
    let history: [[Float]]
    /// When the live CRT path is under pressure, skip texture rebuilds so
    /// this window does not compete with Metal presents.
    var videoGPUBehind: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            SIDPianoKeyGutter()
                .frame(width: 34)
            SIDSpectrogramHeatmap(
                history: history,
                videoGPUBehind: videoGPUBehind)
        }
        .background(Color.black)
    }
}

private struct SIDSpectrogramHeatmap: NSViewRepresentable {
    let history: [[Float]]
    let videoGPUBehind: Bool

    func makeNSView(context: Context) -> SIDSpectrogramNSView {
        let view = SIDSpectrogramNSView()
        view.history = history
        view.videoGPUBehind = videoGPUBehind
        return view
    }

    func updateNSView(_ nsView: SIDSpectrogramNSView, context: Context) {
        nsView.history = history
        nsView.videoGPUBehind = videoGPUBehind
        nsView.refreshIfNeeded()
    }
}

/// Owns a fixed 160×48 RGBA buffer and paints it into `layer.contents`.
/// New spectrum columns scroll in from the right; older columns shift left.
final class SIDSpectrogramNSView: NSView {
    var history: [[Float]] = []
    var videoGPUBehind = false

    private static let columns = SIDEngine.spectrogramColumns
    private static let rows = SIDSpectrumAnalyzer.barCount
    private static let refreshInterval: Double = 1.0 / 30.0

    private var pixels = [UInt8](
        repeating: 0,
        count: SIDEngine.spectrogramColumns * SIDSpectrumAnalyzer.barCount * 4)
    private var lastHistoryCount = 0
    private var lastHistoryTail: [Float] = []
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startTimer()
            refreshIfNeeded(force: true)
        } else {
            stopTimer()
        }
    }

    override func layout() {
        super.layout()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        refreshIfNeeded(force: true)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    func refreshIfNeeded(force: Bool = false) {
        guard !inLiveResize else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        if videoGPUBehind, !force { return }

        let tail = history.last ?? []
        let unchanged = !force
            && history.count == lastHistoryCount
            && tail.elementsEqual(lastHistoryTail)
        if unchanged { return }

        lastHistoryCount = history.count
        lastHistoryTail = tail
        rebuildPixels()
    }

    private func rebuildPixels() {
        let columns = Self.columns
        let rows = Self.rows
        pixels.withUnsafeMutableBufferPointer { buffer in
            buffer.update(repeating: 0)
        }

        guard !history.isEmpty else {
            publishImage()
            return
        }

        // Right-align so new columns appear on the trailing edge while the
        // spectrogram scrolls left as history grows to capacity.
        let startColumn = max(0, columns - history.count)
        for (historyIndex, bars) in history.enumerated() {
            let column = startColumn + historyIndex
            guard column < columns else { continue }
            for row in 0..<rows {
                let value = row < bars.count ? bars[row] : 0
                // CGImage / CALayer treat buffer row 0 as the top of the
                // image; keep analyzer row 0 (lowest frequency) at the bottom
                // to match the piano-key gutter.
                let imageRow = rows - 1 - row
                let offset = (imageRow * columns + column) * 4
                let rgba = Self.fireRGBA(for: value)
                pixels[offset] = rgba.0
                pixels[offset + 1] = rgba.1
                pixels[offset + 2] = rgba.2
                pixels[offset + 3] = 255
            }
        }
        publishImage()
    }

    private func publishImage() {
        let columns = Self.columns
        let rows = Self.rows
        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: columns,
                    height: rows,
                    bitsPerComponent: 8,
                    bytesPerRow: columns * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return context.makeImage()
        }
        guard let image else { return }
        layer?.contents = image
    }

    /// Black → purple → red → orange → yellow "fire" heat ramp.
    private static func fireRGBA(for value: Float) -> (UInt8, UInt8, UInt8) {
        let v = Double(max(0, min(1, value)))
        let r: Double
        let g: Double
        let b: Double
        if v < 0.25 {
            let t = v / 0.25
            r = t * 0.3
            g = 0
            b = t * 0.4
        } else if v < 0.5 {
            let t = (v - 0.25) / 0.25
            r = 0.3 + t * 0.65
            g = 0
            b = 0.4 - t * 0.35
        } else if v < 0.75 {
            let t = (v - 0.5) / 0.25
            r = 0.95
            g = t * 0.55
            b = max(0, 0.05 - t * 0.05)
        } else {
            let t = (v - 0.75) / 0.25
            r = 1
            g = 0.55 + t * 0.4
            b = t * 0.15
        }
        return (
            UInt8(min(255, r * 255)),
            UInt8(min(255, g * 255)),
            UInt8(min(255, b * 255)))
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

private extension Array where Element == Float {
    func elementsEqual(_ other: [Float]) -> Bool {
        guard count == other.count else { return false }
        for index in indices where self[index] != other[index] {
            return false
        }
        return true
    }
}
