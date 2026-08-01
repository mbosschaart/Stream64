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
/// last) picks the pixel's color — reads are green, writes are orange —
/// and fades to black over `fadeDuration`. A busy 6510/VIC trace touches
/// most of its working set many times a second, so `fadeDuration` needs to
/// be short (tens to a couple hundred ms) or the whole grid saturates
/// solid green with no visible detail; it's adjustable live since how
/// short "enough" is depends heavily on the trace mode and what's running.
struct MemoryMapView: View {
    let heatmap: MemoryHeatmap
    /// Which bus this trace is decoding — picks the landmark set (a 1541
    /// drive's memory map has nothing in common with a C64's).
    let source: DebugStreamSource

    static let side = 256
    private static let refreshInterval: Double = 1.0 / 20.0
    private static let defaultFadeDuration: Double = 0.15
    private static let gutterWidth: CGFloat = 108

    @State private var image: CGImage?
    @State private var timer: Timer?
    @State private var fadeDuration = MemoryMapView.defaultFadeDuration

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            GeometryReader { geometry in
                let available = min(
                    geometry.size.width - Self.gutterWidth,
                    geometry.size.height)
                HStack(spacing: 0) {
                    gutter(height: available)
                        .frame(width: Self.gutterWidth, height: available)
                    grid(size: available)
                }
                .frame(width: Self.gutterWidth + available, height: available)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .background(Color.black)
        }
        .background(Color.black)
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("Decay").font(.caption).foregroundStyle(.secondary)
            Slider(value: $fadeDuration, in: 0.02...1.0)
                .frame(width: 150)
            Text(Self.formattedDuration(fadeDuration))
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Spacer()
            legendSwatch(color: .green, label: "Read")
            legendSwatch(color: .orange, label: "Write")
        }
        .padding(8)
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.2f s", seconds)
    }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func grid(size: CGFloat) -> some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .interpolation(.none)
                    .resizable()
            }
        }
        .frame(width: size, height: size)
    }

    /// Left-margin landmark labels. Ticks mark each landmark's *true* row;
    /// label text is vertically spaced out to a minimum readable gap (even
    /// when that means it no longer lines up exactly with its tick) and
    /// connected back to it with a short leader line, so text never
    /// overlaps regardless of how close two landmark rows are.
    private func gutter(height: CGFloat) -> some View {
        let rowHeight = height / CGFloat(Self.side)
        let minLabelGap: CGFloat = 13
        var placements: [(label: String, tickY: CGFloat, textY: CGFloat)] = []
        var previousTextY: CGFloat = -.infinity
        for landmark in Self.landmarkRows(for: source).sorted(by: { $0.row < $1.row }) {
            let tickY = (CGFloat(landmark.row) + 0.5) * rowHeight
            let textY = max(tickY, previousTextY + minLabelGap)
            placements.append((landmark.label, tickY, textY))
            previousTextY = textY
        }

        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                for placement in placements {
                    var path = Path()
                    path.move(to: CGPoint(x: size.width - 8, y: placement.tickY))
                    path.addLine(to: CGPoint(x: size.width - 2, y: placement.tickY))
                    if abs(placement.textY - placement.tickY) > 1 {
                        path.move(to: CGPoint(x: size.width - 10, y: placement.textY))
                        path.addLine(to: CGPoint(x: size.width - 8, y: placement.tickY))
                    }
                    context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1)
                }
            }
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                Text(placement.label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: Self.gutterWidth - 14, alignment: .trailing)
                    .position(x: (Self.gutterWidth - 14) / 2, y: placement.textY)
            }
        }
        .allowsHitTesting(false)
    }

    /// C64 CPU/VIC memory map. `$D000-$DFFF` is shown as VIC/SID/color
    /// RAM/CIA I/O — the normal running configuration — but the same page
    /// range shows Character ROM instead whenever I/O is banked out
    /// (rare: e.g. briefly copying the character set to RAM). There's no
    /// separate row for that since it's the exact same addresses, not an
    /// additional region.
    private static let c64LandmarkRows: [(row: Int, label: String)] = [
        (0x00, "$00 zero page"),
        (0x01, "$01 stack"),
        (0x02, "$02 RAM"),
        (0x04, "$04 screen RAM"),
        (0x08, "$08 BASIC/RAM"),
        (0xA0, "$A0 BASIC ROM"),
        (0xC0, "$C0 RAM"),
        (0xD0, "$D0 VIC-II"),
        (0xD4, "$D4 SID"),
        (0xD8, "$D8 color RAM"),
        (0xDC, "$DC CIA1"),
        (0xDD, "$DD CIA2"),
        (0xDE, "$DE I/O 1"),
        (0xDF, "$DF I/O 2"),
        (0xE0, "$E0 KERNAL ROM"),
    ]

    /// 1541 drive memory map. Much smaller than the C64's: 2 KB of RAM,
    /// two 6522 VIAs (VIA1 talks to the IEC/serial bus; VIA2 drives the
    /// head/motor and reads the write-protect/sync signals), and a 16 KB
    /// DOS ROM. Both VIAs are only 16 registers wide but the 1541's
    /// address decoding is incomplete, so each one is actually mirrored
    /// across its whole `$1800`/`$1C00` page.
    private static let drive1541LandmarkRows: [(row: Int, label: String)] = [
        (0x00, "$00 zero page"),
        (0x01, "$01 stack"),
        (0x02, "$02 RAM/buffers"),
        (0x18, "$18 VIA1 (IEC)"),
        (0x1C, "$1C VIA2 (motor)"),
        (0xC0, "$C0 DOS ROM"),
    ]

    private static func landmarkRows(for source: DebugStreamSource) -> [(row: Int, label: String)] {
        switch source {
        case .cpu6510, .vic: return c64LandmarkRows
        case .drive1541: return drive1541LandmarkRows
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.refreshInterval, repeats: true
        ) { [heatmap] _ in
            let duration = fadeDuration
            let rendered = Self.render(heatmap, fadeDuration: duration)
            DispatchQueue.main.async { self.image = rendered }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Build one frame: for every address, take whichever of read/write
    /// happened most recently, fade its intensity by elapsed time, and
    /// pack the whole 256×256 grid into a `CGImage`. Reads `heatmap`'s
    /// arrays racily off the main actor's usual isolation (see
    /// `MemoryHeatmap`'s doc comment) — safe because a torn read is at
    /// worst one pixel a fraction of a frame stale.
    private static func render(_ heatmap: MemoryHeatmap, fadeDuration: Double) -> CGImage? {
        let now = CFAbsoluteTimeGetCurrent()
        let lastRead = heatmap.lastRead
        let lastWrite = heatmap.lastWrite
        var pixels = [UInt8](repeating: 0, count: MemoryHeatmap.addressSpace * 4)

        for address in 0..<MemoryHeatmap.addressSpace {
            let readAt = lastRead[address]
            let writeAt = lastWrite[address]
            guard readAt > 0 || writeAt > 0 else { continue }

            let isWrite = writeAt > readAt
            let elapsed = now - (isWrite ? writeAt : readAt)
            guard elapsed < fadeDuration else { continue }

            // Square the linear falloff: pixels pop brightly right on
            // access and fall off quickly after, instead of fading evenly
            // across the whole window — much easier to see individual
            // recent accesses rather than a smeared-together block.
            let linear = 1 - elapsed / fadeDuration
            let intensity = linear * linear

            let offset = address * 4
            if isWrite {
                pixels[offset] = UInt8(min(255, intensity * 255))       // R
                pixels[offset + 1] = UInt8(min(255, intensity * 140))   // G (→ orange)
            } else {
                pixels[offset + 1] = UInt8(min(255, intensity * 255))   // G (→ green)
            }
            pixels[offset + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side, height: side,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }
}
