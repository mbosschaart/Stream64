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
    case wiringDiagram = "Wiring Diagram"
    case filterCurve = "Filter Curve"
    case spectrum = "Spectrum Analyzer"
    case lissajous = "Lissajous Scope"
    case spectrogram = "Spectrogram"
    var id: String { rawValue }

    /// Register-driven modes (the default 8) reconstruct their picture
    /// from SID register *writes* seen on the debug trace. These three
    /// instead read the real post-mix Ultimate audio stream, so they need
    /// `AudioReceiver`'s sample tap active instead (or as well).
    var needsAudioTap: Bool {
        switch self {
        case .spectrum, .lissajous, .spectrogram: return true
        default: return false
        }
    }

    var systemImage: String {
        switch self {
        case .oscilloscope: return "waveform"
        case .envelope: return "waveform.path"
        case .mixerConsole: return "slider.vertical.3"
        case .pianoRoll: return "pianokeys"
        case .wiringDiagram: return "point.3.connected.trianglepath.dotted"
        case .filterCurve: return "waveform.path.ecg"
        case .spectrum: return "chart.bar.fill"
        case .lissajous: return "circle.hexagongrid"
        case .spectrogram: return "square.stack.3d.up"
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

@MainActor
final class SIDOscilloscopeViewModel: ObservableObject {
    static let simulationSampleRate = 8000.0
    static let bufferSize = 400 // ~50 ms of trace at the simulation rate
    static let noteHistoryLength = 300 // ~10 s at the 30 Hz tick rate
    static let lissajousBufferSize = 900
    static let spectrogramColumns = 160
    /// Clamp elapsed time between ticks so a stalled/backgrounded window
    /// doesn't try to synthesize a huge backlog of samples the instant it
    /// resumes.
    private static let maxTickSeconds = 0.1

    let session: DeviceSession
    @Published private(set) var channels: [SIDVoiceChannel] = []
    @Published private(set) var chipCount = 1
    @Published private(set) var filterStates: [SIDFilterRegisters] = []

    @Published var visualizationMode: SIDVisualizationMode = .oscilloscope {
        didSet { modeDidChange(from: oldValue) }
    }
    @Published var phosphorGlowEnabled = false

    // Real-audio-tap-derived state (Spectrum/Lissajous/Spectrogram only).
    @Published private(set) var spectrumBars: [Float] = []
    @Published private(set) var spectrogramHistory: [[Float]] = []
    @Published private(set) var lissajousPoints: [(left: Float, right: Float)] = []

    /// The mutable working copies `tick()` steps every sample; the
    /// `@Published` copies the view reads are only reassigned once per
    /// tick, not once per sample — publishing per-sample would fire
    /// hundreds of SwiftUI updates a frame for no visual benefit.
    private var workingChannels: [SIDVoiceChannel] = []
    private var workingFilterStates: [SIDFilterRegisters] = []
    private var chipBaseAddresses: [UInt16] = [0xD400]

    private var pendingVoiceWrites: [(chipIndex: Int, offset: Int, value: UInt8)] = []
    private var pendingFilterWrites: [(chipIndex: Int, offset: Int, value: UInt8)] = []
    private let pendingLock = NSLock()
    private var entriesObserverID: UUID?
    private var audioObserverID: UUID?
    private let spectrumAnalyzer = SIDSpectrumAnalyzer(sampleRate: 47983.0)
    private var lissajousBuffer: [(left: Float, right: Float)] = []
    private var timer: Timer?
    private var lastTick = Date()

    init(session: DeviceSession) {
        self.session = session
    }

    /// Discover the SID address configuration, then attach to the
    /// (persistent, session-owned) receiver and start the synthesis/UI
    /// timer. Call once when the window opens.
    func start() async {
        let config = await UltimateAPIClient(device: session.device).fetchSIDConfiguration()
        configure(with: config)

        entriesObserverID = session.debugStreamReceiver.addEntriesObserver { [weak self] entries in
            guard let self else { return }
            let bases = self.chipBaseAddresses
            var voiceWrites: [(chipIndex: Int, offset: Int, value: UInt8)] = []
            var filterWrites: [(chipIndex: Int, offset: Int, value: UInt8)] = []
            for entry in entries where !entry.isRead {
                for (chipIndex, base) in bases.enumerated() {
                    let offset = Int(entry.address) - Int(base)
                    if offset >= 0, offset < 21 {
                        voiceWrites.append((chipIndex, offset, entry.data))
                        break
                    } else if offset >= 21, offset < 25 {
                        filterWrites.append((chipIndex, offset - 21, entry.data))
                        break
                    }
                }
            }
            guard !voiceWrites.isEmpty || !filterWrites.isEmpty else { return }
            self.pendingLock.lock()
            self.pendingVoiceWrites.append(contentsOf: voiceWrites)
            self.pendingFilterWrites.append(contentsOf: filterWrites)
            self.pendingLock.unlock()
        }

        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        updateAudioTapSubscription()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let entriesObserverID {
            session.debugStreamReceiver.removeEntriesObserver(entriesObserverID)
        }
        if let audioObserverID {
            session.audioReceiver.removeSampleObserver(audioObserverID)
        }
    }

    private func modeDidChange(from oldMode: SIDVisualizationMode) {
        guard oldMode != visualizationMode else { return }
        updateAudioTapSubscription()
        // Fresh start for whichever scrolling buffer the new mode owns,
        // rather than dumping a stale backlog the instant it's selected.
        switch visualizationMode {
        case .lissajous: lissajousBuffer.removeAll(keepingCapacity: true)
        case .spectrogram: spectrogramHistory.removeAll(keepingCapacity: true)
        default: break
        }
    }

    private func updateAudioTapSubscription() {
        let needsTap = visualizationMode.needsAudioTap
        if needsTap, audioObserverID == nil {
            audioObserverID = session.audioReceiver.addSampleObserver { [weak self] interleaved in
                Task { @MainActor [weak self] in self?.handleAudioSamples(interleaved) }
            }
        } else if !needsTap, let id = audioObserverID {
            session.audioReceiver.removeSampleObserver(id)
            audioObserverID = nil
        }
    }

    private func handleAudioSamples(_ interleaved: [Float]) {
        guard visualizationMode.needsAudioTap else { return }
        let frameCount = interleaved.count / 2
        guard frameCount > 0 else { return }
        var mono = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let left = interleaved[i * 2]
            let right = interleaved[i * 2 + 1]
            mono[i] = (left + right) * 0.5
            if visualizationMode == .lissajous {
                lissajousBuffer.append((left, right))
            }
        }
        if lissajousBuffer.count > Self.lissajousBufferSize {
            lissajousBuffer.removeFirst(lissajousBuffer.count - Self.lissajousBufferSize)
        }
        if visualizationMode == .lissajous {
            lissajousPoints = lissajousBuffer
        }

        if visualizationMode == .spectrum || visualizationMode == .spectrogram,
           let bars = spectrumAnalyzer.ingest(mono) {
            spectrumBars = bars
            if visualizationMode == .spectrogram {
                spectrogramHistory.append(bars)
                if spectrogramHistory.count > Self.spectrogramColumns {
                    spectrogramHistory.removeFirst(spectrogramHistory.count - Self.spectrogramColumns)
                }
            }
        }
    }

    private func configure(with config: UltimateAPIClient.SIDConfiguration) {
        chipBaseAddresses = [config.socket1Address]
        if let socket2 = config.socket2Address {
            chipBaseAddresses.append(socket2)
        }
        chipCount = chipBaseAddresses.count
        workingChannels = (0..<chipBaseAddresses.count).flatMap { chip in
            (0..<3).map { voice in
                SIDVoiceChannel(
                    id: chip * 3 + voice, chipIndex: chip, voiceIndex: voice,
                    bufferSize: Self.bufferSize, noteHistoryLength: Self.noteHistoryLength)
            }
        }
        channels = workingChannels
        workingFilterStates = Array(repeating: SIDFilterRegisters(), count: chipBaseAddresses.count)
        filterStates = workingFilterStates
    }

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), Self.maxTickSeconds)
        lastTick = now
        guard dt > 0, !workingChannels.isEmpty else { return }

        pendingLock.lock()
        let voiceWrites = pendingVoiceWrites
        let filterWrites = pendingFilterWrites
        pendingVoiceWrites.removeAll(keepingCapacity: true)
        pendingFilterWrites.removeAll(keepingCapacity: true)
        pendingLock.unlock()

        for write in voiceWrites {
            let index = write.chipIndex * 3 + write.offset / 7
            guard workingChannels.indices.contains(index) else { continue }
            workingChannels[index].registers.write(offset: write.offset % 7, value: write.value)
        }
        for write in filterWrites {
            guard workingFilterStates.indices.contains(write.chipIndex) else { continue }
            workingFilterStates[write.chipIndex].write(offset: write.offset, value: write.value)
        }

        let stepDt = 1.0 / Self.simulationSampleRate
        let sampleCount = max(1, Int((dt * Self.simulationSampleRate).rounded()))
        for _ in 0..<sampleCount {
            // Snapshot each chip's 3 voice phases *before* stepping any of
            // them this sample, so ring modulation reads a consistent
            // (if one-sample-stale) neighbor phase rather than whatever
            // order the voices happen to be stepped in.
            var previousPhases: [[Double]] = Array(
                repeating: [0, 0, 0], count: chipBaseAddresses.count)
            for i in workingChannels.indices {
                previousPhases[workingChannels[i].chipIndex][workingChannels[i].voiceIndex] =
                    workingChannels[i].synth.phase
            }
            for i in workingChannels.indices {
                let chip = workingChannels[i].chipIndex
                let voice = workingChannels[i].voiceIndex
                let neighborVoice = (voice + 2) % 3 // circular: 0←2, 1←0, 2←1
                let neighborPhase = previousPhases[chip][neighborVoice]
                let sample = workingChannels[i].synth.step(
                    dt: stepDt, registers: workingChannels[i].registers,
                    neighborPhase: neighborPhase)
                workingChannels[i].push(sample: Float(sample), envelope: Float(workingChannels[i].synth.envelope))
            }
        }

        for i in workingChannels.indices {
            workingChannels[i].pushNoteHistory()
        }

        channels = workingChannels
        filterStates = workingFilterStates
    }
}

struct SIDOscilloscopeView: View {
    @ObservedObject var model: SIDOscilloscopeViewModel
    @ObservedObject var session: DeviceSession

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !isCapturing6510, !model.visualizationMode.needsAudioTap {
                banner
                Divider()
            }
            content
                .contextMenu {
                    SIDVisualizationMenuContent(model: model)
                }
        }
        .frame(minWidth: 480, minHeight: 220)
    }

    private var toolbar: some View {
        HStack {
            Menu {
                SIDVisualizationMenuContent(model: model)
            } label: {
                Label(model.visualizationMode.rawValue, systemImage: model.visualizationMode.systemImage)
            }
            .frame(width: 220)
            Spacer()
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.visualizationMode {
        case .oscilloscope:
            SIDChannelGrid(channels: model.channels, chipCount: model.chipCount) { channel in
                SIDChannelPanel(channel: channel, glow: model.phosphorGlowEnabled)
            }
        case .envelope:
            SIDChannelGrid(channels: model.channels, chipCount: model.chipCount) { channel in
                SIDEnvelopePanel(channel: channel, glow: model.phosphorGlowEnabled)
            }
        case .mixerConsole:
            SIDChannelGrid(channels: model.channels, chipCount: model.chipCount) { channel in
                SIDMixerStripPanel(channel: channel)
            }
        case .pianoRoll:
            SIDPianoRollView(channels: model.channels)
        case .wiringDiagram:
            SIDWiringDiagramView(channels: model.channels, chipCount: model.chipCount)
        case .filterCurve:
            SIDFilterCurveView(channels: model.channels, filterStates: model.filterStates)
        case .spectrum:
            SIDSpectrumView(bars: model.spectrumBars, glow: model.phosphorGlowEnabled)
        case .lissajous:
            SIDLissajousView(points: model.lissajousPoints, glow: model.phosphorGlowEnabled)
        case .spectrogram:
            SIDSpectrogramView(history: model.spectrogramHistory)
        }
    }

    private var isCapturing6510: Bool {
        if case .active(let mode) = session.debugTraceState {
            return mode.sources.contains(.cpu6510)
        }
        return false
    }

    private var banner: some View {
        HStack {
            Image(systemName: "waveform.slash").foregroundStyle(.orange)
            Text("No 6510 debug trace is running — SID register writes can't be seen without one.")
                .font(.caption)
            Spacer()
            Button("Start 6510 Trace") {
                Task { await session.startDebugTrace(mode: .cpu6510Only) }
            }
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}

/// Shared menu content for both the toolbar "Visualize" dropdown and the
/// window's right-click context menu — one source of truth for the list
/// of modes so the two selection surfaces can't drift apart.
struct SIDVisualizationMenuContent: View {
    @ObservedObject var model: SIDOscilloscopeViewModel

    var body: some View {
        ForEach(SIDVisualizationMode.allCases) { mode in
            Button {
                model.visualizationMode = mode
            } label: {
                if model.visualizationMode == mode {
                    Label(mode.rawValue, systemImage: "checkmark")
                } else {
                    Text(mode.rawValue)
                }
            }
        }
        Divider()
        Toggle("Phosphor Glow", isOn: $model.phosphorGlowEnabled)
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
    private static var windows: [UUID: SIDOscilloscopeWindowController] = [:]

    private let deviceID: UUID
    private let model: SIDOscilloscopeViewModel

    static func show(session: DeviceSession) {
        if let existing = windows[session.device.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SIDOscilloscopeWindowController(session: session)
        windows[session.device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        Task { await controller.model.start() }
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(session: DeviceSession) {
        deviceID = session.device.id
        model = SIDOscilloscopeViewModel(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
            ],
            backing: .buffered, defer: false)
        window.title = "\(session.device.name) SID Oscilloscope"
        window.minSize = NSSize(width: 480, height: 260)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SIDOscilloscopeView(model: model, session: session))
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.windows.removeValue(forKey: deviceID)
    }
}
