import Combine
import SwiftUI
import AppKit

/// Which of the SID Oscilloscope window's visualization modes is active.
/// Selectable from the toolbar "Visualize" menu and the window's
/// right-click context menu (see `SIDVisualizationMenuContent`).
enum SIDVisualizationMode: String, CaseIterable, Identifiable {
    case oscilloscope = "Oscilloscope"
    case envelope = "ADSR Envelope"
    case mixerConsole = "Mixer Console"
    case pianoRoll = "Piano Roll"
    case voiceLineup = "Voice Lineup"
    case filterCurve = "Filter Curve"
    case spectrum = "Spectrum Analyzer"
    case lissajous = "Lissajous Scope"
    case spectrogram = "Spectrogram"
    case waterfall3D = "3D Waterfall"
    case barField3D = "3D Bar Field"
    case vuMeterBank = "VU Meter Bank"
    case registerActivity = "Register Activity"
    case adsrKnobs = "ADSR Knobs"
    case pulseWidth = "Pulse Width"
    case controlBits = "Control Bits"
    case dashboard = "SID Dashboard"
    case colorfulWaveform = "Colorful Waveform"
    var id: String { rawValue }

    /// Register-driven modes reconstruct their picture from SID register
    /// *writes* seen on the debug trace. These five instead read the real
    /// post-mix Ultimate audio stream, so they need `AudioReceiver`'s
    /// sample tap active instead (or as well).
    var needsAudioTap: Bool {
        switch self {
        case .spectrum, .lissajous, .spectrogram, .waterfall3D, .barField3D: return true
        default: return false
        }
    }

    /// Whether this mode needs the audio-rate oscillator/envelope stepping
    /// loop in `tick()` — i.e. it reads `orderedSamples`,
    /// `orderedEnvelopeSamples`, `levelRMS`, or `peakLevel`. Modes that only
    /// show raw register values (ADSR Knobs, Pulse Width, Control Bits,
    /// SID Dashboard, Filter Curve, Register Activity) or note-onset timing
    /// (Piano Roll, Voice Lineup — driven by `pushNoteHistory()`, which
    /// only needs the *current* register values, not synthesized samples)
    /// don't need this at all, and paid for it unconditionally before this
    /// was added.
    var needsSampleSynthesis: Bool {
        switch self {
        case .oscilloscope, .envelope, .mixerConsole, .vuMeterBank, .colorfulWaveform: return true
        default: return false
        }
    }

    /// Whether this mode needs SID register *writes* at all — the inverse
    /// of `needsAudioTap` today, since no mode currently needs both the
    /// debug bus-trace and the raw audio tap. Named separately (rather than
    /// just inlining `!needsAudioTap`) so call sites read as "this mode
    /// needs register writes" instead of a double negative.
    var needsRegisterWrites: Bool { !needsAudioTap }

    /// Whether this mode consumes FFT bar spectra from `SIDSpectrumAnalyzer`
    /// — as opposed to Lissajous, which only needs raw L/R samples.
    var usesSpectrumBars: Bool {
        switch self {
        case .spectrum, .spectrogram, .waterfall3D, .barField3D: return true
        default: return false
        }
    }

    /// Whether this mode needs a scrolling *history* of spectra rather
    /// than just the latest one.
    var usesSpectrogramHistory: Bool {
        switch self {
        case .spectrogram, .waterfall3D, .barField3D: return true
        default: return false
        }
    }

    var systemImage: String {
        switch self {
        case .oscilloscope: return "waveform"
        case .envelope: return "waveform.path"
        case .mixerConsole: return "slider.vertical.3"
        case .pianoRoll: return "pianokeys"
        case .voiceLineup: return "rectangle.stack.fill"
        case .filterCurve: return "waveform.path.ecg"
        case .spectrum: return "chart.bar.fill"
        case .lissajous: return "circle.hexagongrid"
        case .spectrogram: return "square.stack.3d.up"
        case .waterfall3D: return "mountain.2.fill"
        case .barField3D: return "cube.fill"
        case .vuMeterBank: return "gauge"
        case .registerActivity: return "memorychip"
        case .adsrKnobs: return "dial.low"
        case .pulseWidth: return "rectangle.split.3x1"
        case .controlBits: return "switch.2"
        case .dashboard: return "rectangle.3.group"
        case .colorfulWaveform: return "waveform.circle.fill"
        }
    }
}

/// One SID voice as tracked by the oscilloscope: which chip/voice it is,
/// its decoded registers, live oscillator/envelope synthesis state, and
/// ring buffers of recent samples for the various per-voice visualization
/// modes.
struct SIDVoiceChannel: Identifiable {
    let id: Int          // 0...5 — stable SwiftUI identity
    let chipIndex: Int    // 0 or 1
    let voiceIndex: Int   // 0, 1, 2
    var registers = SIDVoiceRegisters()
    var synth = SIDVoiceSynth()

    private var samples: [Float]
    private var envelopeSamples: [Float]
    private var writeIndex = 0

    /// Peak-hold level for the VU Meter Bank mode: jumps instantly to the
    /// loudest recent sample, then decays slowly — the same idea a real
    /// analog VU/PPM meter's peak needle uses, distinct from `levelRMS`
    /// below (which the denser Mixer Console strip uses instead, and
    /// which averages rather than holding a peak).
    private(set) var peakLevel: Float = 0
    /// Tuned so a peak decays to roughly 5% of its value over ~1.5s at
    /// the 8 kHz simulation sample rate `push` is called at.
    private static let peakDecayPerSample: Float = 0.9997

    /// Lower-rate, much longer history for the Piano Roll — the
    /// audio-rate `samples` buffer above is only ~50 ms, far too short for
    /// a scrolling note timeline. Pushed once per view-model tick (~30 Hz)
    /// rather than once per synthesized sample.
    private var noteHistory: [(gate: Bool, frequencyHz: Double)]
    private var noteHistoryWriteIndex = 0

    init(id: Int, chipIndex: Int, voiceIndex: Int, bufferSize: Int, noteHistoryLength: Int) {
        self.id = id
        self.chipIndex = chipIndex
        self.voiceIndex = voiceIndex
        samples = Array(repeating: 0, count: bufferSize)
        envelopeSamples = Array(repeating: 0, count: bufferSize)
        noteHistory = Array(repeating: (false, 0), count: noteHistoryLength)
    }

    mutating func push(sample: Float, envelope: Float) {
        samples[writeIndex] = sample
        envelopeSamples[writeIndex] = envelope
        writeIndex = (writeIndex + 1) % samples.count
        peakLevel = max(peakLevel * Self.peakDecayPerSample, abs(sample))
    }

    /// Clears all reconstructed state back to power-on defaults —
    /// registers, synth, every sample/history buffer, and the peak-hold
    /// level. Used when the user explicitly resets/reboots/powers off
    /// the machine: register writes alone can't reliably signal "the
    /// chip went silent" (a reset may not generate any new writes at
    /// all), so this is called proactively instead of waiting for writes
    /// that might never come. Buffers are zeroed directly (not just left
    /// to `push()` naturally flush them out over the next ~50ms) so the
    /// visual change is instant.
    mutating func resetToSilence() {
        registers = SIDVoiceRegisters()
        synth = SIDVoiceSynth()
        samples = Array(repeating: 0, count: samples.count)
        envelopeSamples = Array(repeating: 0, count: envelopeSamples.count)
        noteHistory = Array(repeating: (false, 0), count: noteHistory.count)
        peakLevel = 0
    }

    mutating func pushNoteHistory() {
        noteHistory[noteHistoryWriteIndex] = (registers.gate, frequencyHz)
        noteHistoryWriteIndex = (noteHistoryWriteIndex + 1) % noteHistory.count
    }

    /// Samples in chronological order (oldest first) for a left-to-right
    /// scrolling trace — `writeIndex` marks the oldest slot (the next one
    /// to be overwritten).
    var orderedSamples: [Float] {
        Array(samples[writeIndex...]) + Array(samples[..<writeIndex])
    }

    var orderedEnvelopeSamples: [Float] {
        Array(envelopeSamples[writeIndex...]) + Array(envelopeSamples[..<writeIndex])
    }

    var orderedNoteHistory: [(gate: Bool, frequencyHz: Double)] {
        Array(noteHistory[noteHistoryWriteIndex...]) + Array(noteHistory[..<noteHistoryWriteIndex])
    }

    /// Root-mean-square of the most recent samples — a simple level
    /// estimate for the Mixer Console's VU-style meter.
    var levelRMS: Float {
        let recent = samples.suffix(64)
        guard !recent.isEmpty else { return 0 }
        return sqrt(recent.reduce(Float(0)) { $0 + $1 * $1 } / Float(recent.count))
    }

    var envelopeStageLabel: String {
        synth.envelopeStageLabel(sustainLevel: Double(registers.sustain) / 15)
    }

    var waveformLabel: String {
        var parts: [String] = []
        if registers.triangleEnabled { parts.append("Tri") }
        if registers.sawtoothEnabled { parts.append("Saw") }
        if registers.pulseEnabled { parts.append("Pulse") }
        if registers.noiseEnabled { parts.append("Noise") }
        return parts.isEmpty ? "—" : parts.joined(separator: "+")
    }

    var frequencyHz: Double {
        Double(registers.frequency) * SIDVoiceSynth.clockHz / 16_777_216
    }

    var noteName: String {
        Self.noteName(forHz: frequencyHz)
    }

    private static let noteLetters = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    static func noteName(forHz hz: Double) -> String {
        guard hz > 1 else { return "—" }
        let midi = 69 + 12 * log2(hz / 440)
        guard midi.isFinite else { return "—" }
        let rounded = Int(midi.rounded())
        guard rounded >= 0, rounded < 128 else { return "—" }
        return "\(noteLetters[rounded % 12])\(rounded / 12 - 1)"
    }
}

/// Thin per-window state: which visualization mode this window shows and
/// whether its phosphor-glow overlay is on — both are genuinely specific
/// to *this* window (two windows on the same device can show different
/// modes, or the same mode with different glow settings). Everything else
/// (the actual SID data) now lives in the shared `SIDEngine` for this
/// window's device — see that type for why. `SIDOscilloscopeView` reads
/// this for `visualizationMode`/`phosphorGlowEnabled` and reads `engine`
/// directly for the data, so it's observing two small, focused objects
/// instead of one that mixed per-window and shared state together.
@MainActor
final class SIDOscilloscopeViewModel: ObservableObject {
    let session: DeviceSession
    let engine: SIDEngine

    @Published var visualizationMode: SIDVisualizationMode = .oscilloscope
    @Published var phosphorGlowEnabled = false

    private var engineToken: SIDEngine.SubscriberToken?

    init(session: DeviceSession) {
        self.session = session
        self.engine = SIDEngine.shared(for: session)
    }

    /// Registers this window with the shared engine for its device. Call
    /// once when the window opens, after `visualizationMode` has already
    /// been set to its final value (see `SIDOscilloscopeWindowController.init`
    /// — a window's mode never changes after creation, so this only ever
    /// needs to compute `SIDEngineNeeds` once).
    func start() {
        engineToken = engine.subscribe(needs: SIDEngineNeeds(mode: visualizationMode))
    }

    func stop() {
        if let engineToken {
            engine.unsubscribe(engineToken)
        }
        engineToken = nil
    }
}

struct SIDOscilloscopeView: View {
    @ObservedObject var model: SIDOscilloscopeViewModel
    /// The shared per-device engine backing `model` — observed directly
    /// (rather than forwarded through `model`) so this view re-renders
    /// whenever the engine's data changes, exactly as if it were still
    /// owned by `model` itself.
    @ObservedObject var engine: SIDEngine
    @ObservedObject var session: DeviceSession

    init(model: SIDOscilloscopeViewModel, session: DeviceSession) {
        self.model = model
        self.engine = model.engine
        self.session = session
    }

    var body: some View {
        content
            .contextMenu {
                SIDVisualizationMenuContent(model: model, session: session)
            }
            .frame(minWidth: 480, minHeight: 220)
    }

    @ViewBuilder
    private var content: some View {
        switch model.visualizationMode {
        case .oscilloscope:
            SIDChannelGrid(channels: engine.channels, chipCount: engine.chipCount) { channel in
                SIDChannelPanel(channel: channel, glow: model.phosphorGlowEnabled)
            }
        case .envelope:
            SIDChannelGrid(channels: engine.channels, chipCount: engine.chipCount) { channel in
                SIDEnvelopePanel(channel: channel, glow: model.phosphorGlowEnabled)
            }
        case .mixerConsole:
            SIDChannelGrid(channels: engine.channels, chipCount: engine.chipCount) { channel in
                SIDMixerStripPanel(channel: channel)
            }
        case .pianoRoll:
            SIDPianoRollView(channels: engine.channels)
        case .voiceLineup:
            SIDVoiceLineupView(channels: engine.channels)
        case .filterCurve:
            SIDFilterCurveView(channels: engine.channels, filterStates: engine.filterStates)
        case .spectrum:
            SIDSpectrumView(bars: engine.spectrumBars, glow: model.phosphorGlowEnabled)
        case .lissajous:
            SIDLissajousView(points: engine.lissajousPoints, glow: model.phosphorGlowEnabled)
        case .spectrogram:
            SIDSpectrogramView(history: engine.spectrogramHistory)
        case .waterfall3D:
            SIDWaterfallSpectrumView(history: engine.spectrogramHistory)
        case .barField3D:
            SID3DBarSpectrumView(history: engine.spectrogramHistory)
        case .vuMeterBank:
            SIDVUMeterBankView(channels: engine.channels)
        case .registerActivity:
            SIDRegisterActivityView(activity: engine.registerActivity)
        case .adsrKnobs:
            SIDChannelGrid(channels: engine.channels, chipCount: engine.chipCount) { channel in
                SIDADSRKnobPanel(channel: channel)
            }
        case .pulseWidth:
            SIDChannelGrid(channels: engine.channels, chipCount: engine.chipCount) { channel in
                SIDPulseWidthPanel(channel: channel)
            }
        case .controlBits:
            SIDChannelGrid(channels: engine.channels, chipCount: engine.chipCount) { channel in
                SIDControlBitsPanel(channel: channel)
            }
        case .dashboard:
            SIDDashboardView(channels: engine.channels, filterStates: engine.filterStates)
        case .colorfulWaveform:
            SIDColorfulWaveformView(channels: engine.channels, glow: model.phosphorGlowEnabled)
        }
    }

}

/// The window's right-click context menu — no toolbar/pulldown menu is
/// shown in the window itself (see `SIDOscilloscopeView.body`), so this is
/// the only in-window way to reach these actions. Every mode entry below
/// always spawns a brand-new, fully independent window (own view model,
/// own timer, own observers) already set to that mode — it never
/// switches *this* window's mode — so several modes can run side by
/// side, e.g. an Oscilloscope window next to a Spectrum Analyzer window.
/// This mirrors the "SID Visualizations" entry on the stream's main
/// right-click menu (`StreamContextMenu`), which behaves identically.
struct SIDVisualizationMenuContent: View {
    @ObservedObject var model: SIDOscilloscopeViewModel
    let session: DeviceSession

    var body: some View {
        ForEach(SIDVisualizationMode.allCases) { mode in
            Button {
                SIDOscilloscopeWindowController.showNewWindow(session: session, mode: mode)
            } label: {
                Label(mode.rawValue, systemImage: mode.systemImage)
            }
        }
        Divider()
        Toggle("Phosphor Glow", isOn: $model.phosphorGlowEnabled)
        Divider()
        Button {
            SIDOscilloscopeWindowController.showAllInGrid(session: session)
        } label: {
            Label("Open All in Grid", systemImage: "square.grid.3x3")
        }
        Divider()
        Button {
            session.saveWindowLayout()
        } label: {
            Label("Save Window Layout", systemImage: "square.and.arrow.down")
        }
        Button {
            session.restoreWindowLayout()
        } label: {
            Label("Restore Window Layout", systemImage: "square.and.arrow.up")
        }
        .disabled(!session.hasSavedWindowLayout)
    }
}

/// Lays out up to `chipCount` rows × 3 columns of per-channel panels,
/// sizing each explicitly from the window's *current* size (no
/// `ScrollView`, no fixed panel size) so panels grow and shrink as the
/// window is resized. Shared by every per-channel-grid visualization mode
/// (Oscilloscope, ADSR Envelope, Mixer Console).
///
/// Layout constants pulled out into a plain enum since Swift doesn't
/// allow static stored properties on generic types (`SIDChannelGrid`
/// below is generic over its panel content).
private enum SIDChannelGridLayout {
    static let columnCount = 3
    static let spacing: CGFloat = 8
}

struct SIDChannelGrid<Panel: View>: View {
    let channels: [SIDVoiceChannel]
    let chipCount: Int
    @ViewBuilder let panel: (SIDVoiceChannel) -> Panel

    private typealias Layout = SIDChannelGridLayout

    var body: some View {
        GeometryReader { geometry in
            let rows = max(chipCount, 1)
            let panelWidth = (geometry.size.width - Layout.spacing * CGFloat(Layout.columnCount + 1))
                / CGFloat(Layout.columnCount)
            let panelHeight = (geometry.size.height - Layout.spacing * CGFloat(rows + 1))
                / CGFloat(rows)
            VStack(spacing: Layout.spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: Layout.spacing) {
                        ForEach(0..<Layout.columnCount, id: \.self) { column in
                            let index = row * Layout.columnCount + column
                            if index < channels.count {
                                panel(channels[index])
                                    .frame(width: panelWidth, height: panelHeight)
                            } else {
                                Color.clear.frame(width: panelWidth, height: panelHeight)
                            }
                        }
                    }
                }
            }
            .padding(Layout.spacing)
        }
        .background(Color.black)
    }
}

/// Common panel chrome (label, gate LED, dark card background) shared by
/// the Oscilloscope and ADSR Envelope panels, which differ only in what
/// they draw in the trace area and how they caption it.
struct SIDPanelChrome<Trace: View, Footer: View>: View {
    let channel: SIDVoiceChannel
    @ViewBuilder let trace: () -> Trace
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SID \(channel.chipIndex + 1) · Channel \(channel.voiceIndex + 1)")
                    .font(.callout).bold()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Circle()
                    .fill(channel.registers.gate ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .help(channel.registers.gate ? "Gate on" : "Gate off")
            }
            trace()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.15)))
            footer()
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .cornerRadius(6)
    }
}

private struct SIDChannelPanel: View {
    let channel: SIDVoiceChannel
    let glow: Bool

    var body: some View {
        SIDPanelChrome(channel: channel) {
            WaveformTrace(samples: channel.orderedSamples, color: .green, bipolar: true, glow: glow)
        } footer: {
            HStack {
                Text(channel.waveformLabel)
                    .font(.system(.caption2, design: .monospaced))
                Spacer()
                Text("\(Int(channel.frequencyHz)) Hz · \(channel.noteName)")
                    .font(.system(.caption2, design: .monospaced))
            }
        }
    }
}

struct SIDEnvelopePanel: View {
    let channel: SIDVoiceChannel
    let glow: Bool

    var body: some View {
        SIDPanelChrome(channel: channel) {
            WaveformTrace(samples: channel.orderedEnvelopeSamples, color: .cyan, bipolar: false, glow: glow)
        } footer: {
            HStack {
                Text("Stage \(channel.envelopeStageLabel)")
                    .font(.system(.caption2, design: .monospaced))
                Spacer()
                Text(String(format: "%.0f%%", channel.synth.envelope * 100))
                    .font(.system(.caption2, design: .monospaced))
            }
        }
    }
}

/// A scrolling line trace shared by the Oscilloscope (bipolar, -1...1) and
/// ADSR Envelope (unipolar, 0...1) modes. `glow` fakes a CRT-phosphor
/// bloom by redrawing the line a few more times with increasing blur and
/// decreasing opacity underneath the crisp top line, rather than a real
/// Metal shader pass — this is a lightweight SwiftUI-only approximation.
struct WaveformTrace: View {
    let samples: [Float]
    let color: Color
    /// `true` centers the trace vertically (oscilloscope-style); `false`
    /// draws 0...1 values from the bottom up (envelope-style).
    let bipolar: Bool
    var glow = false

    var body: some View {
        Canvas { context, size in
            var midline = Path()
            let midY = bipolar ? size.height / 2 : size.height - 2
            midline.move(to: CGPoint(x: 0, y: midY))
            midline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(midline, with: .color(.white.opacity(0.15)), lineWidth: 0.5)

            guard samples.count > 1 else { return }
            let path = Self.path(for: samples, size: size, bipolar: bipolar)

            if glow {
                for (radius, opacity) in [(6.0, 0.12), (3.0, 0.22)] {
                    var glowContext = context
                    glowContext.addFilter(.blur(radius: radius))
                    glowContext.stroke(path, with: .color(color.opacity(opacity)), lineWidth: 2.5)
                }
            }
            context.stroke(path, with: .color(color), lineWidth: 1.3)
        }
    }

    private static func path(for samples: [Float], size: CGSize, bipolar: Bool) -> Path {
        let stepX = size.width / CGFloat(samples.count - 1)
        var path = Path()
        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * stepX
            let y: CGFloat
            if bipolar {
                let amplitude = size.height / 2 - 4
                y = size.height / 2 - CGFloat(sample) * amplitude
            } else {
                y = size.height - 2 - CGFloat(max(0, min(1, sample))) * (size.height - 6)
            }
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

@MainActor
final class SIDOscilloscopeWindowController: NSWindowController, NSWindowDelegate {
    /// Every open window, keyed by its own instance ID — multiple windows
    /// per device are supported (see `showNewWindow`), so this can no
    /// longer be keyed by device ID alone the way the single-window
    /// version was.
    private static var windows: [UUID: SIDOscilloscopeWindowController] = [:]

    private let windowID = UUID()
    private let deviceID: UUID
    private let deviceName: String
    private let model: SIDOscilloscopeViewModel
    private var startupTask: Task<Void, Never>?

    /// Always opens a brand-new, independent window already set to
    /// `mode` — never reuses or replaces any existing window, including
    /// the primary one, so several modes can run side by side.
    static func showNewWindow(session: DeviceSession, mode: SIDVisualizationMode) {
        let controller = SIDOscilloscopeWindowController(session: session, mode: mode)
        windows[controller.windowID] = controller
        controller.presentAndStart()
    }

    /// Opens one independent window per visualization mode, tiled into a
    /// grid across the main screen so every mode can be compared side by
    /// side at a glance. Like `showNewWindow`, always spawns fresh
    /// windows rather than reusing/deduplicating any already open, and
    /// none of them become the device's "primary" window.
    static func showAllInGrid(session: DeviceSession) {
        let modes = SIDVisualizationMode.allCases
        let count = modes.count
        guard count > 0, let screen = NSScreen.main else { return }
        let area = screen.visibleFrame

        // Pack every window at its actual minimum usable size (matching
        // `window.minSize` below) rather than stretching cells to fill
        // whatever space dividing the screen evenly would give each
        // one — with 18 modes, that stretching could make even a simple
        // bar-graph mode occupy a needlessly huge chunk of the screen.
        // `gridLayout` still picks a sensible (rows, columns) split
        // (preferring fewer, wider rows) using this fixed size as the
        // "don't go narrower than this" threshold; the resulting grid
        // is then centered in whatever screen space is left over.
        let minWindowWidth: CGFloat = 300
        let minWindowHeight: CGFloat = 180
        let margin: CGFloat = 4
        // The per-window *cell* must be larger than `window.minSize`
        // below by at least 2x the margin. Each window's requested frame
        // is `cellSize - margin*2` (to leave a gap); if that came out
        // smaller than `window.minSize` (as it did when `cellWidth`/
        // `cellHeight` were set equal to `minSize` directly), AppKit
        // silently clamps the window back up to its minimum without
        // shrinking the gap to match — so windows ended up a full
        // margin's worth bigger than their allotted slot and overlapped
        // their neighbors instead of leaving a visible gap.
        let cellWidth = minWindowWidth + margin * 2
        let cellHeight = minWindowHeight + margin * 2
        let (rows, columns) = gridLayout(count: count, screenWidth: area.width, minCellWidth: cellWidth)

        let gridWidth = CGFloat(columns) * cellWidth
        let gridHeight = CGFloat(rows) * cellHeight
        let originX = area.minX + max(0, (area.width - gridWidth) / 2)
        let originY = area.minY + max(0, (area.height - gridHeight) / 2)

        for (index, mode) in modes.enumerated() {
            let row = index / columns
            let column = index % columns
            let frame = NSRect(
                x: originX + CGFloat(column) * cellWidth + margin,
                y: originY + CGFloat(rows - row - 1) * cellHeight + margin,
                width: cellWidth - margin * 2,
                height: cellHeight - margin * 2)

            let controller = SIDOscilloscopeWindowController(session: session, mode: mode)
            windows[controller.windowID] = controller
            // Windows themselves appear immediately (all 11 at once,
            // for instant visual feedback), but each one's *data*
            // startup — a SID-config REST fetch, and possibly a
            // debug-trace start if nothing else has started one yet —
            // is staggered a little. Firing all 11 of those requests in
            // the same instant briefly overwhelmed the Ultimate's small
            // embedded HTTP server enough to fail an unrelated
            // in-flight debug-capability probe (also REST, also a few
            // seconds' timeout), which made the Debug Trace/Ultimate
            // Menu/SID Oscilloscope menu entries disappear for a bit
            // until the next successful probe — see `HANDOVER.md` §16.
            controller.presentAndStart(frame: frame, startDelay: Double(index) * 0.25)
        }
    }

    /// Whether any SID Oscilloscope window is currently open for
    /// `deviceID` — used to disable "Save Window Layout" when there's
    /// nothing to save.
    static func hasAnyOpenWindows(for deviceID: UUID) -> Bool {
        windows.values.contains { $0.deviceID == deviceID }
    }

    /// Captures every open SID Oscilloscope window for `deviceID` — its
    /// mode and on-screen frame — as a snapshot `restoreLayout` can
    /// later recreate.
    static func currentLayout(for deviceID: UUID) -> [SIDWindowLayoutEntry] {
        windows.values
            .filter { $0.deviceID == deviceID }
            .compactMap { controller -> SIDWindowLayoutEntry? in
                guard let frame = controller.window?.frame else { return nil }
                return SIDWindowLayoutEntry(mode: controller.model.visualizationMode.rawValue, frame: frame)
            }
    }

    /// Closes every currently open SID Oscilloscope window for
    /// `deviceID`. Snapshots the matching controllers into a plain array
    /// first — closing a window synchronously fires `windowWillClose`,
    /// which mutates `windows` (a dictionary) via `removeValue`, and
    /// mutating a dictionary while iterating its own `.values` view
    /// directly is unsafe.
    static func closeAll(for deviceID: UUID) {
        let matching = windows.values.filter { $0.deviceID == deviceID }
        for controller in matching {
            controller.window?.close()
        }
    }

    /// Re-opens one window per saved entry at its saved frame and mode,
    /// after first closing whatever SID Oscilloscope windows are already
    /// open for this device (so restoring doesn't just pile new windows
    /// on top of old ones). Mirrors `showAllInGrid`'s staggered
    /// `model.start()` calls so restoring a large saved layout doesn't
    /// hit the Ultimate's HTTP server with a burst of simultaneous
    /// requests.
    static func restoreLayout(_ entries: [SIDWindowLayoutEntry], session: DeviceSession) {
        closeAll(for: session.device.id)
        for (index, entry) in entries.enumerated() {
            guard let mode = SIDVisualizationMode(rawValue: entry.mode) else { continue }
            let controller = SIDOscilloscopeWindowController(session: session, mode: mode)
            windows[controller.windowID] = controller
            controller.presentAndStart(frame: entry.frame, startDelay: Double(index) * 0.25)
        }
    }

    /// Chooses a (rows, columns) grid for `count` windows across a
    /// screen `screenWidth` points wide, preferring as few rows as fit
    /// comfortably — a wide grid reads better for side-by-side
    /// comparison than a tall stack of narrow windows — but falling back
    /// to more rows rather than squeezing cells narrower than
    /// `minCellWidth`. Pulled out of `showAllInGrid` as a pure function
    /// so the layout math itself is unit-testable without needing a
    /// real `NSScreen`.
    nonisolated static func gridLayout(count: Int, screenWidth: CGFloat, minCellWidth: CGFloat) -> (rows: Int, columns: Int) {
        guard count > 0 else { return (0, 0) }
        for candidateRows in 1...count {
            let candidateColumns = Int((Double(count) / Double(candidateRows)).rounded(.up))
            if screenWidth / CGFloat(candidateColumns) >= minCellWidth {
                return (candidateRows, candidateColumns)
            }
        }
        return (count, 1)
    }

    private init(session: DeviceSession, mode: SIDVisualizationMode) {
        deviceID = session.device.id
        deviceName = session.device.name
        model = SIDOscilloscopeViewModel(session: session)
        model.visualizationMode = mode
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
            ],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 300, height: 180)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SIDOscilloscopeView(model: model, session: session))
        // The mode is fixed for this window's lifetime (see the type
        // comment on `SIDVisualizationMenuContent` — picking a different
        // mode always opens another window rather than changing this
        // one), so the title only needs to be set once here.
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }

    private func presentAndStart(frame: NSRect? = nil, startDelay: TimeInterval = 0) {
        if let frame {
            window?.setFrame(frame, display: false)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            if startDelay > 0 {
                try? await Task.sleep(for: .seconds(startDelay))
            }
            guard !Task.isCancelled, let self, self.window != nil else { return }
            self.model.start()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateTitle() {
        let base = "\(deviceName) SID Oscilloscope"
        window?.title = model.visualizationMode == .oscilloscope
            ? base : "\(base) — \(model.visualizationMode.rawValue)"
    }

    func windowWillClose(_ notification: Notification) {
        startupTask?.cancel()
        startupTask = nil
        model.stop()
        Self.windows.removeValue(forKey: windowID)
    }
}
