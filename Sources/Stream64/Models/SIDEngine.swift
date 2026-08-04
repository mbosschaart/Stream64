import Combine
import Foundation

/// Which of a device's shared subsystems a given open SID Oscilloscope
/// window currently needs, derived once from its `SIDVisualizationMode`.
/// `SIDEngine` aggregates these across every subscribed window (the union
/// of all their needs) to decide what shared work is actually worth doing
/// — e.g. two windows both showing register-driven modes only need one
/// debug-trace subscription and one synthesis pass between them, not two.
struct SIDEngineNeeds: Hashable {
    var needsRegisterWrites: Bool
    var needsSampleSynthesis: Bool
    var needsAudioTap: Bool
    var usesSpectrumBars: Bool
    var usesSpectrogramHistory: Bool
    /// Lissajous is the one audio-tap mode that needs neither
    /// `usesSpectrumBars` nor `usesSpectrogramHistory` (it plots raw L/R
    /// samples, not FFT bars), so it needs its own flag rather than being
    /// derivable from the others.
    var needsLissajousPoints: Bool

    init(mode: SIDVisualizationMode) {
        needsRegisterWrites = mode.needsRegisterWrites
        needsSampleSynthesis = mode.needsSampleSynthesis
        needsAudioTap = mode.needsAudioTap
        usesSpectrumBars = mode.usesSpectrumBars
        usesSpectrogramHistory = mode.usesSpectrogramHistory
        needsLissajousPoints = mode == .lissajous
    }

    private init(
        needsRegisterWrites: Bool, needsSampleSynthesis: Bool, needsAudioTap: Bool,
        usesSpectrumBars: Bool, usesSpectrogramHistory: Bool, needsLissajousPoints: Bool
    ) {
        self.needsRegisterWrites = needsRegisterWrites
        self.needsSampleSynthesis = needsSampleSynthesis
        self.needsAudioTap = needsAudioTap
        self.usesSpectrumBars = usesSpectrumBars
        self.usesSpectrogramHistory = usesSpectrogramHistory
        self.needsLissajousPoints = needsLissajousPoints
    }

    static let none = SIDEngineNeeds(
        needsRegisterWrites: false, needsSampleSynthesis: false, needsAudioTap: false,
        usesSpectrumBars: false, usesSpectrogramHistory: false, needsLissajousPoints: false)

    /// The union of two sets of needs — "does at least one of us need X."
    func union(_ other: SIDEngineNeeds) -> SIDEngineNeeds {
        SIDEngineNeeds(
            needsRegisterWrites: needsRegisterWrites || other.needsRegisterWrites,
            needsSampleSynthesis: needsSampleSynthesis || other.needsSampleSynthesis,
            needsAudioTap: needsAudioTap || other.needsAudioTap,
            usesSpectrumBars: usesSpectrumBars || other.usesSpectrumBars,
            usesSpectrogramHistory: usesSpectrogramHistory || other.usesSpectrogramHistory,
            needsLissajousPoints: needsLissajousPoints || other.needsLissajousPoints)
    }
}

/// Drives SID register-write decoding, audio-rate oscillator/envelope
/// synthesis, and FFT/spectrum analysis **once per device**, shared by
/// every open SID Oscilloscope window on that device — regardless of how
/// many are open or which of the 18 visualization modes each one shows.
///
/// Before this existed, each window ran a fully independent copy of all of
/// this: its own 30 Hz timer, its own debug-trace filtering, its own 8 kHz
/// synthesis loop, its own FFT (see `SIDOscilloscopeViewModel`, now a thin
/// per-window adapter over this engine instead). With several windows open
/// on the same device — easily 18 at once via "Open All in Grid" — that
/// was the same work repeated N times over for no benefit, since the
/// underlying SID state is identical regardless of how many windows are
/// looking at it. This class does it exactly once and publishes the
/// result; windows just read it.
@MainActor
final class SIDEngine: ObservableObject {
    static let simulationSampleRate = 8000.0
    static let bufferSize = 400 // ~50 ms of trace at the simulation rate
    static let noteHistoryLength = 300 // ~10 s at the 30 Hz tick rate
    static let lissajousBufferSize = 900
    static let spectrogramColumns = 160
    /// Clamp elapsed time between ticks so a stalled/backgrounded engine
    /// doesn't try to synthesize a huge backlog of samples the instant it
    /// resumes.
    private static let maxTickSeconds = 0.1

    private static var instances: [UUID: SIDEngine] = [:]

    /// Looks up (or creates) the shared engine for `session`'s device.
    /// Every subscriber must eventually call `unsubscribe(_:)` with the
    /// token `subscribe(needs:)` returns — once the last one does, the
    /// engine tears itself down and removes itself from this registry, so
    /// a later call here for the same device starts completely fresh
    /// rather than resurrecting stale state or leaving a 30 Hz timer
    /// running for a device with no SID windows open anymore.
    static func shared(for session: DeviceSession) -> SIDEngine {
        if let existing = instances[session.device.id] { return existing }
        let created = SIDEngine(session: session)
        instances[session.device.id] = created
        return created
    }

    struct SubscriberToken: Hashable {
        fileprivate let id = UUID()
    }

    let session: DeviceSession

    @Published private(set) var channels: [SIDVoiceChannel] = []
    @Published private(set) var chipCount = 1
    @Published private(set) var filterStates: [SIDFilterRegisters] = []
    @Published private(set) var registerActivity = SIDRegisterActivity(chipCount: 1)
    // Real-audio-tap-derived state (Spectrum/Lissajous/Spectrogram/3D modes).
    @Published private(set) var spectrumBars: [Float] = []
    @Published private(set) var spectrogramHistory: [[Float]] = []
    @Published private(set) var lissajousPoints: [(left: Float, right: Float)] = []

    private var subscribers: [SubscriberToken: SIDEngineNeeds] = [:]
    private var aggregateNeeds: SIDEngineNeeds = .none

    /// The mutable working copies `tick()` steps every sample; the
    /// `@Published` copies every window's view reads are only reassigned
    /// once per tick, not once per sample.
    private var workingChannels: [SIDVoiceChannel] = []
    private var workingFilterStates: [SIDFilterRegisters] = []
    private var workingRegisterActivity = SIDRegisterActivity(chipCount: 1)
    private var chipBaseAddresses: [UInt16] = [0xD400]

    private var pendingVoiceWrites: [(chipIndex: Int, offset: Int, value: UInt8)] = []
    private var pendingFilterWrites: [(chipIndex: Int, offset: Int, value: UInt8)] = []
    private let pendingLock = NSLock()
    private var entriesObserverID: UUID?
    private var audioObserverID: UUID?
    private var debugTraceLease: UUID?
    /// Guards against attaching a second `entriesObserver`/kicking off a
    /// second SID-config fetch if multiple subscribers needing register
    /// writes join while the first fetch is still in flight — see
    /// `enableRegisterWrites()`.
    private var registerWritesEnabled = false
    private let spectrumAnalyzer = SIDSpectrumAnalyzer(sampleRate: SIDSpectrumAnalyzer.defaultSampleRate)
    private var lissajousBuffer: [(left: Float, right: Float)] = []
    /// Raw interleaved samples from the audio tap, appended on
    /// `AudioReceiver`'s own queue and drained once per `tick()` (30 Hz)
    /// rather than processed with a `Task` hop to `@MainActor` per UDP
    /// packet.
    private var pendingAudioSamples: [Float] = []
    private let audioLock = NSLock()
    private var timer: Timer?
    private var lastTick = Date()
    private var resetObservation: AnyCancellable?

    private init(session: DeviceSession) {
        self.session = session
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // `.dropFirst()` because `$machineResetToken` immediately replays
        // its *current* value to a new subscriber — without it, a freshly
        // created engine would clear state it hasn't even configured yet
        // for no reason, though harmlessly.
        resetObservation = session.$machineResetToken.dropFirst().sink { [weak self] _ in
            self?.handleMachineReset()
        }
    }

    /// Registers a window's needs (derived from its `SIDVisualizationMode`)
    /// and starts whichever shared subsystems no *other* current
    /// subscriber already needed — the SID-config fetch and debug-trace
    /// observer, or the audio-tap observer — gated independently. Callers
    /// must hold onto the returned token and pass it to `unsubscribe(_:)`
    /// when their window closes.
    func subscribe(needs: SIDEngineNeeds) -> SubscriberToken {
        let token = SubscriberToken()
        let before = aggregateNeeds
        subscribers[token] = needs
        recomputeAggregateNeeds()
        applyNeedsTransition(from: before, to: aggregateNeeds)
        return token
    }

    /// Unregisters a subscriber. If it was the last one, tears the engine
    /// down completely (invalidates the timer, removes every observer)
    /// and removes it from the shared registry, so a device with no SID
    /// windows open never has a lingering 30 Hz timer running for it.
    func unsubscribe(_ token: SubscriberToken) {
        guard subscribers.removeValue(forKey: token) != nil else { return }
        if subscribers.isEmpty {
            teardown()
            return
        }
        let before = aggregateNeeds
        recomputeAggregateNeeds()
        applyNeedsTransition(from: before, to: aggregateNeeds)
    }

    private func recomputeAggregateNeeds() {
        aggregateNeeds = subscribers.values.reduce(.none) { $0.union($1) }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        registerWritesEnabled = false
        if let entriesObserverID {
            session.debugStreamReceiver.removeEntriesObserver(entriesObserverID)
            self.entriesObserverID = nil
        }
        if let debugTraceLease {
            self.debugTraceLease = nil
            Task { await session.releaseDebugTrace(debugTraceLease) }
        }
        if let audioObserverID {
            session.audioReceiver.removeSampleObserver(audioObserverID)
            self.audioObserverID = nil
        }
        resetObservation = nil
        // Reset *before* removing from `instances` — any `enableRegisterWrites()`
        // task still in flight for this (now-orphaned) instance checks this
        // flag after its awaits and must see "nobody needs this anymore"
        // rather than attach an observer nobody will ever read.
        aggregateNeeds = .none
        Self.instances.removeValue(forKey: session.device.id)
    }

    private func applyNeedsTransition(from before: SIDEngineNeeds, to after: SIDEngineNeeds) {
        if after.needsRegisterWrites, !before.needsRegisterWrites {
            Task { await self.enableRegisterWrites() }
        } else if !after.needsRegisterWrites, before.needsRegisterWrites {
            disableRegisterWrites()
        }

        if after.needsAudioTap, !before.needsAudioTap {
            enableAudioTap()
        } else if !after.needsAudioTap, before.needsAudioTap {
            disableAudioTap()
        }

        // Fresh start for whichever scrolling buffer just became needed,
        // rather than immediately showing a stale backlog to the window
        // that just asked for it.
        if after.needsLissajousPoints, !before.needsLissajousPoints {
            lissajousBuffer.removeAll(keepingCapacity: true)
        }
        if after.usesSpectrogramHistory, !before.usesSpectrogramHistory {
            spectrogramHistory.removeAll(keepingCapacity: true)
        }
    }

    /// Discover the SID address configuration, then start (if needed) a
    /// 6510-inclusive debug trace and attach to the bus-trace receiver.
    /// Called once whenever the aggregate need for register writes first
    /// goes from "nobody" to "somebody" across every window on this
    /// device — not once per window the way this used to work.
    private func enableRegisterWrites() async {
        guard !registerWritesEnabled else { return }
        registerWritesEnabled = true

        let config = await UltimateAPIClient(device: session.device).fetchSIDConfiguration()
        configure(with: config)

        debugTraceLease = await session.acquireDebugTrace(mode: .cpu6510Only)

        // A subscriber may have dropped its need for register writes
        // again while the two awaits above were in flight (its window
        // closed almost immediately, or the engine was torn down
        // entirely) — don't attach an observer nobody needs anymore.
        guard aggregateNeeds.needsRegisterWrites else {
            if let debugTraceLease {
                self.debugTraceLease = nil
                await session.releaseDebugTrace(debugTraceLease)
            }
            registerWritesEnabled = false
            return
        }

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
    }

    private func disableRegisterWrites() {
        registerWritesEnabled = false
        if let debugTraceLease {
            self.debugTraceLease = nil
            Task { await session.releaseDebugTrace(debugTraceLease) }
        }
        if let entriesObserverID {
            session.debugStreamReceiver.removeEntriesObserver(entriesObserverID)
            self.entriesObserverID = nil
        }
        pendingLock.lock()
        pendingVoiceWrites.removeAll(keepingCapacity: true)
        pendingFilterWrites.removeAll(keepingCapacity: true)
        pendingLock.unlock()
    }

    private func enableAudioTap() {
        guard audioObserverID == nil else { return }
        audioObserverID = session.audioReceiver.addSampleObserver { [weak self] interleaved in
            guard let self else { return }
            self.audioLock.lock()
            self.pendingAudioSamples.append(contentsOf: interleaved)
            self.audioLock.unlock()
        }
    }

    private func disableAudioTap() {
        guard let id = audioObserverID else { return }
        session.audioReceiver.removeSampleObserver(id)
        audioObserverID = nil
        audioLock.lock()
        pendingAudioSamples.removeAll(keepingCapacity: true)
        audioLock.unlock()
    }

    /// Called when the user explicitly resets/reboots/powers off the
    /// machine (see `DeviceSession.machineResetToken`) — clears every bit
    /// of reconstructed state back to silence instead of leaving whatever
    /// was last derived from register writes before the reset on screen
    /// indefinitely.
    private func handleMachineReset() {
        for i in workingChannels.indices {
            workingChannels[i].resetToSilence()
        }
        channels = workingChannels
        workingFilterStates = workingFilterStates.map { _ in SIDFilterRegisters() }
        filterStates = workingFilterStates
        lissajousBuffer.removeAll(keepingCapacity: true)
        lissajousPoints = []
        spectrogramHistory.removeAll(keepingCapacity: true)
        spectrumBars = []
    }

    /// Drains whatever audio samples accumulated since the last tick and
    /// processes them all at once — called once per `tick()`, independent
    /// of the register-driven synthesis below, so it still runs even
    /// before `configure(with:)` has resolved the SID address (when
    /// `workingChannels` is still empty).
    private func drainPendingAudioSamples() {
        guard aggregateNeeds.needsAudioTap else { return }
        audioLock.lock()
        let samples = pendingAudioSamples
        pendingAudioSamples.removeAll(keepingCapacity: true)
        audioLock.unlock()
        guard !samples.isEmpty else { return }
        handleAudioSamples(samples)
    }

    private func handleAudioSamples(_ interleaved: [Float]) {
        guard aggregateNeeds.needsAudioTap else { return }
        let frameCount = interleaved.count / 2
        guard frameCount > 0 else { return }
        var mono = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let left = interleaved[i * 2]
            let right = interleaved[i * 2 + 1]
            mono[i] = (left + right) * 0.5
            if aggregateNeeds.needsLissajousPoints {
                lissajousBuffer.append((left, right))
            }
        }
        if lissajousBuffer.count > Self.lissajousBufferSize {
            lissajousBuffer.removeFirst(lissajousBuffer.count - Self.lissajousBufferSize)
        }
        if aggregateNeeds.needsLissajousPoints {
            lissajousPoints = lissajousBuffer
        }

        if aggregateNeeds.usesSpectrumBars, let bars = spectrumAnalyzer.ingest(mono) {
            spectrumBars = bars
            if aggregateNeeds.usesSpectrogramHistory {
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
        workingRegisterActivity = SIDRegisterActivity(chipCount: chipBaseAddresses.count)
        registerActivity = workingRegisterActivity
    }

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), Self.maxTickSeconds)
        lastTick = now

        drainPendingAudioSamples()

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
            workingRegisterActivity.record(chipIndex: write.chipIndex, offset: write.offset, at: now)
        }
        for write in filterWrites {
            guard workingFilterStates.indices.contains(write.chipIndex) else { continue }
            workingFilterStates[write.chipIndex].write(offset: write.offset, value: write.value)
            // Filter writes' offset is already relative to *within* the
            // filter block (0..<4, reduced by -21 when first decoded in
            // the entries observer above) — add it back to land in the
            // same absolute 0..<25 numbering `SIDRegisterActivity` uses.
            workingRegisterActivity.record(chipIndex: write.chipIndex, offset: write.offset + 21, at: now)
        }

        // Register-only visualizations do not need a published-state update
        // on every timer tick. When there are no writes to apply, publishing
        // the same large channel/filter arrays still invalidates every open
        // SwiftUI SID window and can starve the main thread when several
        // visualizations are open together. Audio-driven modes publish from
        // `handleAudioSamples`; synthesized modes continue through the loop.
        if voiceWrites.isEmpty,
           filterWrites.isEmpty,
           !aggregateNeeds.needsSampleSynthesis {
            return
        }

        // The audio-rate oscillator/envelope stepping loop below is the
        // single most expensive part of `tick()` — only run it while at
        // least one current subscriber actually needs its output
        // (`orderedSamples`, `orderedEnvelopeSamples`, `levelRMS`,
        // `peakLevel`). Register writes are still applied above
        // unconditionally either way.
        if aggregateNeeds.needsSampleSynthesis {
            let stepDt = 1.0 / Self.simulationSampleRate
            let sampleCount = max(1, Int((dt * Self.simulationSampleRate).rounded()))
            // Sized once per tick and reused across every sample below,
            // rather than reallocated on each of the ~267 iterations — its
            // size (chip count × 3 voices) never changes within a tick.
            var previousPhases: [[Double]] = Array(
                repeating: [0, 0, 0], count: chipBaseAddresses.count)
            for _ in 0..<sampleCount {
                // Snapshot each chip's 3 voice phases *before* stepping any
                // of them this sample, so ring modulation reads a
                // consistent (if one-sample-stale) neighbor phase rather
                // than whatever order the voices happen to be stepped in.
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
        }

        for i in workingChannels.indices {
            workingChannels[i].pushNoteHistory()
        }

        channels = workingChannels
        filterStates = workingFilterStates
        registerActivity = workingRegisterActivity
    }
}
