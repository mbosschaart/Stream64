import SwiftUI
import AppKit

/// Real-time 256×256 memory-map heatmap: row = address high byte (page),
/// column = address low byte, so the grid reads top-to-bottom as
/// increasing addresses in 256-byte bands — zero page and stack sit in the
/// first two rows, screen RAM/VIC registers/color RAM/KERNAL ROM each form
/// their own recognizable horizontal band, labelled in a gutter to the left
/// of the grid (not overlaid on top of it — at 256 rows, adjacent
/// landmarks like zero page/stack are only a few pixels apart, too close
/// for overlaid text; labels here are de-overlapped and connected back to
/// their true row with a tick + leader line instead).
///
/// The most recent event per address (read or write, whichever happened
/// last) always picks the pixel's color — reads are green, writes are
/// orange — but what picks its *brightness* depends on `visualization`:
///
/// - **I/O Fade** (the original mode): brightness fades to black over
///   `fadeDuration`, so the picture shows recent *activity*. A busy
///   6510/VIC trace touches most of its working set many times a second,
///   so `fadeDuration` needs to be short (tens to a couple hundred ms) or
///   the whole grid saturates solid green with no visible detail; it's
///   adjustable live since how short "enough" is depends heavily on the
///   trace mode and what's running.
/// - **Byte Load**: brightness is the address's byte value itself (0 =
///   black, 255 = full brightness) and does *not* fade — it's a snapshot
///   of memory *content*, not of recent access, so a touched address stays
///   at its last-known brightness until touched again with a different
///   value (or the trace resets). Useful for spotting, at a glance, which
///   regions hold "interesting" (non-zero/varied) data versus zero-filled
///   or untouched memory.
///
/// The pixel grid itself is an AppKit view that owns a reusable bitmap and
/// blits into its layer — pushing a fresh `CGImage` through SwiftUI `@State`
/// every frame was enough to corrupt window-server/Metal compositing when
/// this window was resized (thin garbage strip, black void, and the main
/// viewer going half-dead at the same time).
/// Which of the two brightness models the memory map is currently showing —
/// see `MemoryMapView`'s doc comment for what each one means.
enum MemoryMapVisualization: String, CaseIterable, Identifiable {
    case ioFade = "I/O Fade"
    case byteLoad = "Byte Load"
    case threeD = "3D Map"
    var id: String { rawValue }
}

/// Mutable renderer-only settings shared by the native toolbar control and
/// the AppKit heatmap surface. Deliberately not `ObservableObject`: dragging
/// the decay slider should update one scalar consumed by the 20 Hz renderer,
/// not publish through and repeatedly rebuild the whole Debug Trace SwiftUI
/// hierarchy (which has previously destabilized the window's compositing).
final class MemoryMapRenderSettings {
    var fadeDuration: Double = 0.15
}

struct MemoryMapView: View {
    let heatmap: MemoryHeatmap
    /// Which bus this trace is decoding — picks the landmark set (a 1541
    /// drive's memory map has nothing in common with a C64's).
    let source: DebugStreamSource
    let visualization: MemoryMapVisualization
    let renderSettings: MemoryMapRenderSettings
    let threeDInteraction: MemoryMap3DInteraction
    let threeDOptions: MemoryMap3DOptions

    static let side = 256
    /// Wide enough for labels such as "Char ROM (banked)" without truncation.
    private static let gutterWidth: CGFloat = 124
    /// Blank surround around the complete gutter + map block. Apart from
    /// looking less cramped, this keeps the first/last landmark rows clear
    /// of the titlebar and window's rounded bottom edge.
    private static let mapInset: CGFloat = 18

    @ViewBuilder
    var body: some View {
        if visualization == .threeD {
            MemoryMap3DView(
                heatmap: heatmap,
                source: source,
                options: threeDOptions,
                interaction: threeDInteraction)
                .padding(Self.mapInset)
                .background(Color.black)
        } else {
            GeometryReader { geometry in
                let available = max(
                    0,
                    min(
                        geometry.size.width - Self.gutterWidth - Self.mapInset * 2,
                        geometry.size.height - Self.mapInset * 2))
                HStack(spacing: 0) {
                    gutter(height: available)
                        .frame(width: Self.gutterWidth, height: available)
                    MemoryHeatmapGridView(
                        heatmap: heatmap,
                        visualization: visualization,
                        renderSettings: renderSettings)
                        .frame(width: available, height: available)
                        .clipped()
                }
                .frame(
                    width: Self.gutterWidth + available,
                    height: available)
                .position(
                    x: geometry.size.width / 2,
                    y: Self.mapInset + available / 2)
            }
            .background(Color.black)
        }
    }

    /// A left-gutter landmark. Most cover a single row (`topRow ==
    /// bottomRow`) and get a short horizontal tick; `isAlternate` ones
    /// (currently just Character ROM) cover a *span* of rows they share
    /// with another landmark rather than owning their own address range,
    /// and get a vertical bracket instead, in a dimmer color, so they read
    /// as "also true here" rather than "this row is X."
    private struct Landmark {
        let topRow: Int
        let bottomRow: Int
        let label: String
        var isAlternate = false
        init(_ row: Int, _ label: String) {
            self.topRow = row
            self.bottomRow = row
            self.label = label
        }
        init(_ rows: ClosedRange<Int>, alternate label: String) {
            self.topRow = rows.lowerBound
            self.bottomRow = rows.upperBound
            self.label = label
            self.isAlternate = true
        }
        var midRow: Double { (Double(topRow) + Double(bottomRow)) / 2 }
    }

    /// Left-margin landmark labels. Ticks mark each landmark's *true* row
    /// (or, for a span, its vertical center); label text is vertically
    /// spaced out to a minimum readable gap (even when that means it no
    /// longer lines up exactly with its tick) and connected back to it with
    /// a short leader line, so text never overlaps regardless of how close
    /// two landmark rows are.
    private func gutter(height: CGFloat) -> some View {
        let rowHeight = height > 0 ? height / CGFloat(Self.side) : 0
        let minLabelGap: CGFloat = 13
        let labelHalfHeight: CGFloat = 6
        var placements: [(landmark: Landmark, tickY: CGFloat, textY: CGFloat)] = []
        var previousTextY = labelHalfHeight - minLabelGap
        for landmark in Self.landmarkRows(for: source).sorted(by: { $0.midRow < $1.midRow }) {
            let tickY = (landmark.midRow + 0.5) * rowHeight
            let textY = max(
                labelHalfHeight,
                tickY,
                previousTextY + minLabelGap)
            placements.append((landmark, tickY, textY))
            previousTextY = textY
        }
        // The forward pass above prevents overlaps, but a cluster near the
        // bottom can push its final labels outside the gutter. Walk upward
        // again from a clamped last row so every label remains fully visible
        // while preserving the same minimum spacing.
        if !placements.isEmpty {
            placements[placements.count - 1].textY = min(
                placements[placements.count - 1].textY,
                max(labelHalfHeight, height - labelHalfHeight))
            if placements.count > 1 {
                for index in stride(
                    from: placements.count - 2,
                    through: 0,
                    by: -1
                ) {
                    placements[index].textY = min(
                        placements[index].textY,
                        placements[index + 1].textY - minLabelGap)
                }
            }
        }

        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                for placement in placements {
                    let color = Color.white.opacity(placement.landmark.isAlternate ? 0.4 : 0.6)
                    var path = Path()
                    if placement.landmark.isAlternate {
                        // A bracket spanning the shared rows instead of a
                        // single tick, so it reads as "this whole range,"
                        // not "this one row."
                        let topY = (CGFloat(placement.landmark.topRow)) * rowHeight
                        let bottomY = (CGFloat(placement.landmark.bottomRow) + 1) * rowHeight
                        path.move(to: CGPoint(x: size.width - 5, y: topY))
                        path.addLine(to: CGPoint(x: size.width - 2, y: topY))
                        path.move(to: CGPoint(x: size.width - 2, y: topY))
                        path.addLine(to: CGPoint(x: size.width - 2, y: bottomY))
                        path.addLine(to: CGPoint(x: size.width - 5, y: bottomY))
                    } else {
                        path.move(to: CGPoint(x: size.width - 8, y: placement.tickY))
                        path.addLine(to: CGPoint(x: size.width - 2, y: placement.tickY))
                    }
                    if abs(placement.textY - placement.tickY) > 1 {
                        path.move(to: CGPoint(x: size.width - 10, y: placement.textY))
                        path.addLine(to: CGPoint(x: size.width - 8, y: placement.tickY))
                    }
                    context.stroke(
                        path, with: .color(color),
                        style: StrokeStyle(
                            lineWidth: 1,
                            dash: placement.landmark.isAlternate ? [3, 2] : []))
                }
            }
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                Text(placement.landmark.label)
                    .font(.system(size: 9, design: .monospaced))
                    .italic(placement.landmark.isAlternate)
                    .foregroundStyle(.white.opacity(placement.landmark.isAlternate ? 0.65 : 1))
                    .lineLimit(1)
                    .frame(width: Self.gutterWidth - 14, alignment: .trailing)
                    .position(x: (Self.gutterWidth - 14) / 2, y: placement.textY)
            }
        }
        .allowsHitTesting(false)
    }

    /// C64 CPU/VIC memory map. `$D000-$DFFF` is shown as VIC/SID/color
    /// RAM/CIA I/O — the normal running configuration — but the same page
    /// range shows Character ROM instead whenever I/O is banked out (rare:
    /// e.g. briefly copying the character set to RAM). It's the exact same
    /// addresses, not an additional region, so it's marked as a dashed
    /// "alternate" bracket over that whole span rather than its own row.
    private static let c64LandmarkRows: [Landmark] = [
        Landmark(0x00, "$00 zero page"),
        Landmark(0x01, "$01 stack"),
        Landmark(0x02, "$02 RAM"),
        Landmark(0x04, "$04 screen RAM"),
        Landmark(0x08, "$08 BASIC/RAM"),
        Landmark(0xA0, "$A0 BASIC ROM"),
        Landmark(0xC0, "$C0 RAM"),
        Landmark(0xD0, "$D0 VIC-II"),
        Landmark(0xD4, "$D4 SID"),
        Landmark(0xD8, "$D8 color RAM"),
        Landmark(0xDC, "$DC CIA1"),
        Landmark(0xDD, "$DD CIA2"),
        Landmark(0xDE, "$DE I/O 1"),
        Landmark(0xDF, "$DF I/O 2"),
        Landmark(0xE0, "$E0 KERNAL ROM"),
        Landmark(0xD0...0xDF, alternate: "Char ROM (banked)"),
    ]

    /// 1541 drive memory map. Much smaller than the C64's: 2 KB of RAM,
    /// two 6522 VIAs (VIA1 talks to the IEC/serial bus; VIA2 drives the
    /// head/motor and reads the write-protect/sync signals), and a 16 KB
    /// DOS ROM. Both VIAs are only 16 registers wide but the 1541's
    /// address decoding is incomplete, so each one is actually mirrored
    /// across its whole `$1800`/`$1C00` page.
    private static let drive1541LandmarkRows: [Landmark] = [
        Landmark(0x00, "$00 zero page"),
        Landmark(0x01, "$01 stack"),
        Landmark(0x02, "$02 RAM/buffers"),
        Landmark(0x18, "$18 VIA1 (IEC)"),
        Landmark(0x1C, "$1C VIA2 (motor)"),
        Landmark(0xC0, "$C0 DOS ROM"),
    ]

    private static func landmarkRows(for source: DebugStreamSource) -> [Landmark] {
        switch source {
        case .cpu6510, .vic: return c64LandmarkRows
        case .drive1541: return drive1541LandmarkRows
        }
    }
}

/// SwiftUI wrapper around the AppKit heatmap surface. The visualization mode
/// changes discretely through SwiftUI; continuously changing render settings
/// are shared by reference so slider drags don't rebuild this view.
private struct MemoryHeatmapGridView: NSViewRepresentable {
    let heatmap: MemoryHeatmap
    var visualization: MemoryMapVisualization
    let renderSettings: MemoryMapRenderSettings

    func makeNSView(context: Context) -> MemoryHeatmapNSView {
        let view = MemoryHeatmapNSView()
        view.heatmap = heatmap
        view.visualization = visualization
        view.renderSettings = renderSettings
        return view
    }

    func updateNSView(_ nsView: MemoryHeatmapNSView, context: Context) {
        nsView.heatmap = heatmap
        nsView.visualization = visualization
        nsView.renderSettings = renderSettings
    }
}

/// Owns a reusable 256×256 RGBA buffer and paints it into `layer.contents`.
/// Refresh is driven by a timer on the common run-loop modes so live window
/// resizing (event-tracking mode) doesn't stall updates and then dump a
/// backlog of SwiftUI image replacements when the drag ends.
final class MemoryHeatmapNSView: NSView {
    var heatmap: MemoryHeatmap?
    var visualization: MemoryMapVisualization = .ioFade
    var renderSettings: MemoryMapRenderSettings?

    private static let side = MemoryMapView.side
    private static let refreshInterval: Double = 1.0 / 20.0

    /// Persistent pixel store — overwritten in place each tick so we don't
    /// allocate a fresh 256 KB buffer (+ `Data` + `CGImage` provider) twenty
    /// times a second through SwiftUI's diffing path.
    private var pixels = [UInt8](
        repeating: 0,
        count: MemoryHeatmap.addressSpace * 4)
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    /// Static overlay of thin lines at every cell boundary, evoking a CRT
    /// shadow mask/aperture grille — purely cosmetic, redrawn only when the
    /// view's pixel size actually changes (see `layout()`), not on the 20 Hz
    /// heatmap refresh timer, since the pattern itself never changes.
    private let gridLayer = CALayer()
    private var lastGridSize: CGSize = .zero

    private func commonInit() {
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.black.cgColor
        gridLayer.contentsGravity = .resize
        layer?.addSublayer(gridLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startTimer()
            refresh()
        } else {
            stopTimer()
        }
    }

    override func layout() {
        super.layout()
        // Keep the layer's contents scale honest across Retina / display
        // moves without forcing a SwiftUI-side image rebuild.
        let scale = window?.backingScaleFactor ?? 1
        layer?.contentsScale = scale
        gridLayer.frame = bounds
        gridLayer.contentsScale = scale
        if bounds.size != lastGridSize, bounds.width > 0, bounds.height > 0 {
            lastGridSize = bounds.size
            gridLayer.contents = Self.renderGrid(size: bounds.size, scale: scale)
        }
    }

    /// One thin line (1 device pixel, so it stays hairline-crisp on Retina)
    /// at every one of the 256 row/column boundaries — deliberately subtle
    /// (low, constant opacity regardless of the heatmap colors underneath)
    /// so it reads as texture, not as competing with the actual data.
    private static func renderGrid(size: CGSize, scale: CGFloat) -> CGImage? {
        let pixelWidth = max(1, Int(size.width * scale))
        let pixelHeight = max(1, Int(size.height * scale))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
        context.setLineWidth(1)
        let cellWidth = CGFloat(pixelWidth) / CGFloat(side)
        let cellHeight = CGFloat(pixelHeight) / CGFloat(side)
        for column in 1..<side {
            let x = (CGFloat(column) * cellWidth).rounded() + 0.5
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: CGFloat(pixelHeight)))
        }
        for row in 1..<side {
            let y = (CGFloat(row) * cellHeight).rounded() + 0.5
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: CGFloat(pixelWidth), y: y))
        }
        context.strokePath()
        return context.makeImage()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Catch up immediately once the drag ends — refreshes are skipped
        // while `inLiveResize` is set so we don't fight the window server.
        refresh()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
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

    /// Build one frame: for every address, use its explicitly tracked last
    /// access direction to pick the color (green/orange), work out its
    /// brightness according to `visualization`, and pack the whole
    /// 256×256 grid into a `CGImage` hung off the layer. Reads `heatmap`'s
    /// arrays racily off the main actor's usual isolation (see
    /// `MemoryHeatmap`'s doc comment) — safe because a torn read is at
    /// worst one pixel a fraction of a frame stale.
    private func refresh() {
        // Live window resizing already has the window server reallocating
        // surfaces; rebuilding layer contents on top of that is what used
        // to leave the thin garbage strip / black void and knock out the
        // main Metal viewer at the same time.
        guard !inLiveResize else { return }
        guard let heatmap, bounds.width > 0, bounds.height > 0 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let lastAccess = heatmap.lastAccess
        let lastAccessWasRead = heatmap.lastAccessWasRead
        let lastValue = heatmap.lastValue
        let fade = renderSettings?.fadeDuration ?? 0.15
        let mode = visualization
        // Zero only alpha-bearing slots would leave stale RGB; the buffer is
        // small enough that a full clear is cheaper than tracking dirty spans.
        pixels.withUnsafeMutableBufferPointer { buffer in
            buffer.update(repeating: 0)
        }

        for address in 0..<MemoryHeatmap.addressSpace {
            let accessedAt = lastAccess[address]
            guard accessedAt > 0 else { continue }

            let isWrite = !lastAccessWasRead[address]
            let intensity: Double
            switch mode {
            case .ioFade:
                let elapsed = now - accessedAt
                guard elapsed < fade else { continue }
                // Square the linear falloff: pixels pop brightly right on
                // access and fall off quickly after, instead of fading
                // evenly across the whole window — much easier to see
                // individual recent accesses rather than a smeared-together
                // block.
                let linear = 1 - elapsed / fade
                intensity = linear * linear
            case .byteLoad, .threeD:
                // A persistent snapshot of content, not of recency — no
                // fade, and no elapsed-time cutoff: the pixel keeps this
                // brightness until the address is next touched, however
                // long ago that was.
                intensity = Double(lastValue[address]) / 255
            }

            let offset = address * 4
            if isWrite {
                pixels[offset] = UInt8(min(255, intensity * 255))       // R
                pixels[offset + 1] = UInt8(min(255, intensity * 140))   // G (→ orange)
            } else {
                pixels[offset + 1] = UInt8(min(255, intensity * 255))   // G (→ green)
            }
            pixels[offset + 3] = 255
        }

        let side = Self.side
        // Wrap the existing buffer in a context and snapshot a CGImage for
        // the layer. The snapshot copies the pixels, so the next tick can
        // safely clear/reuse `pixels` without racing the previous frame.
        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return context.makeImage()
        }
        guard let image else { return }
        layer?.contents = image
    }
}
