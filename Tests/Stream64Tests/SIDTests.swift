import XCTest
import CryptoKit
import ZIPFoundation
import MetalKit
import AVFoundation
@testable import Stream64

final class SIDTests: XCTestCase {
    func testWaveformLabelNamesNoiseAndDigiActivity() {
        var channel = SIDVoiceChannel(
            id: 0,
            chipIndex: 0,
            voiceIndex: 0,
            bufferSize: 32,
            noteHistoryLength: 16)
        XCTAssertEqual(channel.waveformLabel, "No waveform")

        channel.registers.control = 0x80
        XCTAssertEqual(channel.waveformLabel, "Noise")

        channel.registers.control = 0
        channel.digiActivity = 1
        XCTAssertEqual(channel.waveformLabel, "Digi ($D418)")
    }

    func testViewerPaneDroppableExtensionsIncludeSIDAndCRT() {
        XCTAssertTrue(ViewerPane.droppableExtensions.contains("sid"))
        XCTAssertTrue(ViewerPane.droppableExtensions.contains("crt"))
        XCTAssertTrue(ViewerPane.droppableExtensions.contains("prg"))
        XCTAssertTrue(ViewerPane.droppableExtensions.contains("d64"))
    }


    func testSIDEngineAdaptiveTickAndSampleCap() {
        XCTAssertEqual(
            SIDEngine.effectiveTickInterval(subscriberCount: 1),
            1.0 / 30.0,
            accuracy: 0.0001)
        XCTAssertEqual(
            SIDEngine.effectiveTickInterval(subscriberCount: 6),
            1.0 / 15.0,
            accuracy: 0.0001)
        XCTAssertEqual(
            SIDEngine.effectiveTickInterval(subscriberCount: 12),
            1.0 / 10.0,
            accuracy: 0.0001)
        XCTAssertEqual(
            SIDEngine.effectiveTickInterval(
                subscriberCount: 1, videoDisplayBehind: true),
            1.0 / 12.0,
            accuracy: 0.0001)
        XCTAssertEqual(
            SIDEngine.synthesisSampleCap(subscriberCount: 1, requested: 267),
            267)
        XCTAssertEqual(
            SIDEngine.synthesisSampleCap(subscriberCount: 6, requested: 267),
            133)
        XCTAssertEqual(
            SIDEngine.synthesisSampleCap(subscriberCount: 12, requested: 267),
            66)
        XCTAssertEqual(
            SIDEngine.synthesisSampleCap(
                subscriberCount: 1, requested: 267, videoDisplayBehind: true),
            66)
    }


    func testSIDEngineAudioMailboxDropsOldestWhenCapped() {
        var pending: [Float] = Array(repeating: 1, count: 8)
        SIDEngine.appendCappedAudioSamples(
            &pending,
            Array(repeating: 2, count: 6),
            maxCount: 10)
        XCTAssertEqual(pending.count, 10)
        XCTAssertEqual(pending.first, 1)
        XCTAssertEqual(pending.last, 2)
        // Four of the original ones should remain, then six new samples.
        XCTAssertEqual(pending.filter { $0 == 1 }.count, 4)
        XCTAssertEqual(pending.filter { $0 == 2 }.count, 6)
        XCTAssertEqual(SIDEngine.maxPendingAudioSamples, 10_000)
    }


    func testSIDVoiceRegistersDecodeFrequencyPulseWidthAndControlBits() {
        var registers = SIDVoiceRegisters()
        registers.write(offset: 0, value: 0x34) // freq lo
        registers.write(offset: 1, value: 0x12) // freq hi
        registers.write(offset: 2, value: 0xAB) // pulse width lo
        registers.write(offset: 3, value: 0xFF) // pulse width hi (masked to 4 bits)
        let gate: UInt8 = 0x01, triangle: UInt8 = 0x10, pulse: UInt8 = 0x40, noise: UInt8 = 0x80
        registers.write(offset: 4, value: gate | triangle | pulse | noise)
        registers.write(offset: 5, value: 0x9A) // attack=9, decay=A
        registers.write(offset: 6, value: 0x5C) // sustain=5, release=C

        XCTAssertEqual(registers.frequency, 0x1234)
        XCTAssertEqual(registers.pulseWidth, 0x0FAB)
        XCTAssertTrue(registers.gate)
        XCTAssertFalse(registers.syncEnabled)
        XCTAssertFalse(registers.ringModEnabled)
        XCTAssertFalse(registers.test)
        XCTAssertTrue(registers.triangleEnabled)
        XCTAssertFalse(registers.sawtoothEnabled)
        XCTAssertTrue(registers.pulseEnabled)
        XCTAssertTrue(registers.noiseEnabled)
        XCTAssertEqual(registers.attack, 9)
        XCTAssertEqual(registers.decay, 0xA)
        XCTAssertEqual(registers.sustain, 5)
        XCTAssertEqual(registers.release, 0xC)
    }


    func testSIDVoiceSynthTriangleReachesFullRangeAfterAttack() {
        var registers = SIDVoiceRegisters()
        registers.write(offset: 1, value: 0x10) // frequency = 0x1000 (~240 Hz)
        registers.write(offset: 4, value: 0x11) // gate + triangle
        registers.write(offset: 5, value: 0x00) // fastest attack/decay
        registers.write(offset: 6, value: 0xF0) // full sustain, fastest release

        var synth = SIDVoiceSynth()
        let dt = 1.0 / SIDVoiceSynth.clockHz
        let totalSteps = Int(0.05 / dt)
        var minValue = 1.0, maxValue = -1.0
        for step in 0..<totalSteps {
            let sample = synth.step(dt: dt, registers: registers, neighborPhase: 0)
            if step > totalSteps / 2 { // only once envelope/oscillator have settled
                minValue = min(minValue, sample)
                maxValue = max(maxValue, sample)
            }
        }
        XCTAssertGreaterThan(maxValue, 0.9)
        XCTAssertLessThan(minValue, -0.9)
    }


    func testSIDVoiceSynthEnvelopeReleasesTowardZeroWhenGateClears() {
        var registers = SIDVoiceRegisters()
        registers.write(offset: 1, value: 0x10)
        registers.write(offset: 4, value: 0x11) // gate + triangle
        registers.write(offset: 5, value: 0x00) // fastest attack/decay
        registers.write(offset: 6, value: 0xF0) // full sustain, fastest release

        var synth = SIDVoiceSynth()
        let dt = 1.0 / SIDVoiceSynth.clockHz
        for _ in 0..<Int(0.02 / dt) {
            _ = synth.step(dt: dt, registers: registers, neighborPhase: 0)
        }
        XCTAssertGreaterThan(synth.envelope, 0.9) // fully attacked into sustain

        registers.write(offset: 4, value: 0x10) // clear gate, keep triangle selected
        for _ in 0..<Int(0.05 / dt) {
            _ = synth.step(dt: dt, registers: registers, neighborPhase: 0)
        }
        XCTAssertLessThan(synth.envelope, 0.1)
    }


    func testSIDVoiceSynthPulseRespectsPulseWidth() {
        var registers = SIDVoiceRegisters()
        registers.write(offset: 1, value: 0x08) // frequency = 0x0800 (~120 Hz)
        registers.write(offset: 2, value: 0x00)
        registers.write(offset: 3, value: 0x02) // pulse width = 0x200 → duty ≈ 12.5%
        registers.write(offset: 4, value: 0x41) // gate + pulse
        registers.write(offset: 5, value: 0x00)
        registers.write(offset: 6, value: 0xF0) // full sustain

        var synth = SIDVoiceSynth()
        let dt = 1.0 / SIDVoiceSynth.clockHz
        for _ in 0..<Int(0.01 / dt) { // let the envelope settle first
            _ = synth.step(dt: dt, registers: registers, neighborPhase: 0)
        }

        var highCount = 0
        var total = 0
        for _ in 0..<Int(0.2 / dt) { // ~24 periods, enough to average out edge effects
            let sample = synth.step(dt: dt, registers: registers, neighborPhase: 0)
            total += 1
            if sample > 0 { highCount += 1 }
        }
        let ratio = Double(highCount) / Double(total)
        XCTAssertEqual(ratio, 512.0 / 4095.0, accuracy: 0.02)
    }


    func testSIDSpectrumAnalyzerPeaksAtInputSineFrequency() throws {
        let sampleRate = 48000.0
        let analyzer = SIDSpectrumAnalyzer(sampleRate: sampleRate)
        let toneHz = 2000.0

        // Feed enough sine samples for several FFT frames so the window
        // has settled; keep the last non-nil bar spectrum.
        var lastBars: [Float]?
        var phase = 0.0
        let totalSamples = SIDSpectrumAnalyzer.fftSize * 4
        var samples = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            samples[i] = Float(sin(phase))
            phase += 2 * Double.pi * toneHz / sampleRate
        }
        // Feed in FFT-sized chunks, same as a real caller would.
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 256, samples.count)
            if let bars = analyzer.ingest(Array(samples[offset..<end])) {
                lastBars = bars
            }
            offset = end
        }

        let bars = try XCTUnwrap(lastBars)
        XCTAssertEqual(bars.count, SIDSpectrumAnalyzer.barCount)

        // The loudest bar should be one whose log-spaced frequency range
        // covers (or is very close to) 2 kHz.
        let peakIndex = bars.indices.max(by: { bars[$0] < bars[$1] })!
        let nyquist = sampleRate / 2
        let minFrequency = 40.0
        let peakBarFrequency = minFrequency * pow(nyquist / minFrequency, Double(peakIndex) / Double(bars.count))
        XCTAssertEqual(peakBarFrequency, toneHz, accuracy: toneHz * 0.5)
    }


    func testSIDFilterRegistersDecodeCutoffResonanceRoutingAndMode() {
        var filter = SIDFilterRegisters()
        filter.write(offset: 0, value: 0x05) // cutoff lo (3 bits used)
        filter.write(offset: 1, value: 0x3C) // cutoff hi
        let resonance: UInt8 = 0x90 // resonance=9, voice1+voice2 routed
        filter.write(offset: 2, value: resonance | 0x03)
        let mode: UInt8 = 0x0A | 0x10 // volume=10, low-pass enabled
        filter.write(offset: 3, value: mode)

        XCTAssertEqual(filter.cutoffValue, (0x3C << 3) | 0x05)
        XCTAssertEqual(filter.resonance, 9)
        XCTAssertTrue(filter.voiceRouted(0))
        XCTAssertTrue(filter.voiceRouted(1))
        XCTAssertFalse(filter.voiceRouted(2))
        XCTAssertFalse(filter.externalRouted)
        XCTAssertEqual(filter.volume, 10)
        XCTAssertTrue(filter.lowPassEnabled)
        XCTAssertFalse(filter.bandPassEnabled)
        XCTAssertFalse(filter.highPassEnabled)
        XCTAssertFalse(filter.voice3Disconnected)

        // Cutoff-to-Hz is a monotonic approximation, not a specific value.
        XCTAssertLessThan(
            SIDFilterRegisters.approximateCutoffHz(0),
            SIDFilterRegisters.approximateCutoffHz(2047))
    }


    @MainActor
    func testSIDVoiceChannelNoteHistoryRecordsGateAndFrequencyOverTime() {
        var channel = SIDVoiceChannel(
            id: 0, chipIndex: 0, voiceIndex: 0, bufferSize: 8, noteHistoryLength: 4)
        channel.registers.write(offset: 0, value: 0x00)
        channel.registers.write(offset: 1, value: 0x10) // some frequency
        channel.registers.write(offset: 4, value: 0x01) // gate on

        channel.pushNoteHistory()
        channel.registers.write(offset: 4, value: 0x00) // gate off
        channel.pushNoteHistory()

        let history = channel.orderedNoteHistory
        XCTAssertEqual(history.count, 4) // fixed ring-buffer size
        // Most recent two entries (end of the chronological array) are the
        // ones just pushed: gate-on then gate-off, same frequency.
        XCTAssertTrue(history[2].gate)
        XCTAssertFalse(history[3].gate)
        XCTAssertEqual(history[2].frequencyHz, history[3].frequencyHz, accuracy: 0.01)
    }


    func testSIDVoiceChannelResetToSilenceClearsAllReconstructedState() {
        var channel = SIDVoiceChannel(
            id: 0, chipIndex: 0, voiceIndex: 0, bufferSize: 8, noteHistoryLength: 4)
        channel.registers.write(offset: 0, value: 0x34) // frequency lo
        channel.registers.write(offset: 1, value: 0x12) // frequency hi
        channel.registers.write(offset: 4, value: 0x11) // gate on, triangle
        channel.push(sample: 0.8, envelope: 0.9)
        channel.pushNoteHistory()

        XCTAssertNotEqual(channel.registers, SIDVoiceRegisters())
        XCTAssertGreaterThan(channel.peakLevel, 0)
        XCTAssertTrue(channel.orderedSamples.contains { $0 != 0 })

        channel.resetToSilence()

        XCTAssertEqual(channel.registers, SIDVoiceRegisters())
        XCTAssertEqual(channel.peakLevel, 0)
        XCTAssertTrue(channel.orderedSamples.allSatisfy { $0 == 0 })
        XCTAssertTrue(channel.orderedEnvelopeSamples.allSatisfy { $0 == 0 })
        XCTAssertTrue(channel.orderedNoteHistory.allSatisfy { !$0.gate })
        XCTAssertFalse(channel.registers.gate)
        XCTAssertEqual(channel.frequencyHz, 0)
    }


    func testSIDVoiceChannelPeakLevelHoldsThenDecays() {
        var channel = SIDVoiceChannel(
            id: 0, chipIndex: 0, voiceIndex: 0, bufferSize: 8, noteHistoryLength: 4)
        XCTAssertEqual(channel.peakLevel, 0)

        channel.push(sample: 0.9, envelope: 1)
        XCTAssertEqual(channel.peakLevel, 0.9, accuracy: 0.001)

        // A much quieter sample right after should not immediately drop
        // the peak to that quiet level — peak-hold decays slowly rather
        // than tracking instantaneously like the RMS-based level does.
        channel.push(sample: 0.05, envelope: 1)
        XCTAssertGreaterThan(channel.peakLevel, 0.5)

        // Enough further silence should let it decay meaningfully.
        for _ in 0..<2000 {
            channel.push(sample: 0, envelope: 1)
        }
        XCTAssertLessThan(channel.peakLevel, 0.5)
    }


    func testSIDVisualizationModeNeedsSampleSynthesisOnlyForWaveformDrivenModes() {
        // The audio-rate oscillator/envelope stepping loop in `tick()` is
        // by far the most expensive part of a window's update cycle — only
        // the modes that actually read its output (waveform samples, RMS
        // level, or peak-hold level) should require it.
        let waveformDriven: Set<SIDVisualizationMode> = [
            .oscilloscope, .envelope, .mixerConsole, .vuMeterBank,
            .colorfulWaveform, .kaos,
        ]
        for mode in SIDVisualizationMode.allCases {
            XCTAssertEqual(
                mode.needsSampleSynthesis, waveformDriven.contains(mode),
                "\(mode.rawValue) needsSampleSynthesis mismatch")
        }
    }


    func testSIDVisualizationModeRegisterAndAudioNeeds() {
        // KAOS is intentionally hybrid: register events identify musical
        // pattern while post-mix energy supplies sample/digi beat response.
        for mode in SIDVisualizationMode.allCases {
            let expectedRegisterWrites = mode == .kaos || !mode.needsAudioTap
            XCTAssertEqual(
                mode.needsRegisterWrites,
                expectedRegisterWrites,
                "\(mode.rawValue) mismatch")
        }
        // Spot-check both directions explicitly rather than only the
        // derived relationship above.
        XCTAssertTrue(SIDVisualizationMode.oscilloscope.needsRegisterWrites)
        XCTAssertFalse(SIDVisualizationMode.spectrum.needsRegisterWrites)
        XCTAssertTrue(SIDVisualizationMode.kaos.needsRegisterWrites)
        XCTAssertTrue(SIDVisualizationMode.kaos.needsAudioTap)
    }


    func testSIDEngineNeedsMatchesModeFlagsForAllVisualizationModes() {
        for mode in SIDVisualizationMode.allCases {
            let needs = SIDEngineNeeds(mode: mode)
            XCTAssertEqual(needs.needsRegisterWrites, mode.needsRegisterWrites, "\(mode.rawValue)")
            XCTAssertEqual(needs.needsSampleSynthesis, mode.needsSampleSynthesis, "\(mode.rawValue)")
            XCTAssertEqual(needs.needsAudioTap, mode.needsAudioTap, "\(mode.rawValue)")
            XCTAssertEqual(needs.usesSpectrumBars, mode.usesSpectrumBars, "\(mode.rawValue)")
            XCTAssertEqual(needs.usesSpectrogramHistory, mode.usesSpectrogramHistory, "\(mode.rawValue)")
            // KAOS composites the existing real-audio Lissajous motif with
            // its beat/rhythm scene library.
            XCTAssertEqual(
                needs.needsLissajousPoints,
                mode == .lissajous || mode == .kaos,
                "\(mode.rawValue)")
            XCTAssertEqual(needs.needsKAOSRhythm, mode == .kaos, "\(mode.rawValue)")
        }
    }

    func testKAOSRhythmUsesRegisterEventsAndAudioEnergy() {
        var rhythm = KAOSRhythmState()
        var channel = SIDVoiceChannel(
            id: 0, chipIndex: 0, voiceIndex: 0,
            bufferSize: 8, noteHistoryLength: 8)
        channel.registers.control = 0x81
        channel.push(sample: 0.8, envelope: 1)

        rhythm.advance(
            timestamp: 1,
            events: [.gateRise, .digiVolumeStep],
            spectrumBars: Array(repeating: 0.7, count: 24),
            channels: [channel])
        XCTAssertGreaterThan(rhythm.beatPulse, 0.9)
        XCTAssertGreaterThan(rhythm.digiActivity, 0.9)
        XCTAssertNotEqual(rhythm.activeVoiceMask, 0)
        XCTAssertGreaterThan(rhythm.masterLevel, 0)

        rhythm.advance(
            timestamp: 1.5,
            events: [.gateRise],
            spectrumBars: Array(repeating: 0.8, count: 24),
            channels: [channel])
        XCTAssertGreaterThan(rhythm.inferredBPM, 100)
        XCTAssertLessThan(rhythm.inferredBPM, 140)
        XCTAssertGreaterThan(rhythm.beatConfidence, 0)
    }


    func testSIDEngineNeedsUnionIsTrueIfEitherSideNeedsIt() {
        // Oscilloscope needs register writes + sample synthesis; Spectrum
        // Analyzer needs the audio tap + spectrum bars instead — two
        // subscribers with non-overlapping needs should aggregate to the
        // union of both, not just one or the other.
        let oscilloscope = SIDEngineNeeds(mode: .oscilloscope)
        let spectrum = SIDEngineNeeds(mode: .spectrum)
        let union = oscilloscope.union(spectrum)

        XCTAssertTrue(union.needsRegisterWrites)
        XCTAssertTrue(union.needsSampleSynthesis)
        XCTAssertTrue(union.needsAudioTap)
        XCTAssertTrue(union.usesSpectrumBars)
        // Neither side needs these, so the union shouldn't either.
        XCTAssertFalse(union.usesSpectrogramHistory)
        XCTAssertFalse(union.needsLissajousPoints)
    }


    @MainActor
    func testSIDEngineSuspendClearsStickyEnableSoResumeCanRetry() async {
        let session = DeviceSession(
            device: UltimateDevice(name: "SID Suspend Test", host: "192.0.2.9"),
            settings: AppSettings())
        let engine = SIDEngine.shared(for: session)
        let token = engine.subscribe(needs: SIDEngineNeeds(mode: .registerActivity)) {}
        defer { engine.unsubscribe(token) }

        // Simulate a failed-or-partial enable leaving the sticky flag set,
        // then session teardown — resume must be allowed to call enable again.
        engine.suspendForSessionTeardown()
        XCTAssertTrue(SIDEngine.existing(for: session.device.id) === engine)
        engine.resumeAfterSessionConnect()
        // resume schedules enableRegisterWrites; engine must still exist
        // with the subscriber attached.
        XCTAssertTrue(SIDEngine.existing(for: session.device.id) === engine)
    }

    @MainActor
    func testSIDEngineSharedReturnsSameInstanceUntilLastSubscriberLeaves() {
        let session = DeviceSession(
            device: UltimateDevice(name: "SIDEngine Test", host: "192.0.2.1"),
            settings: AppSettings())

        let engineA = SIDEngine.shared(for: session)
        let tokenA = engineA.subscribe(needs: SIDEngineNeeds(mode: .registerActivity)) {}

        // A second subscribe for the same device must reuse the same
        // engine instance, not create a competing one.
        let engineB = SIDEngine.shared(for: session)
        XCTAssertTrue(engineA === engineB)
        let tokenB = engineB.subscribe(needs: SIDEngineNeeds(mode: .adsrKnobs)) {}

        engineA.unsubscribe(tokenA)
        // One of two subscribers left — the engine must still be alive
        // and still be the one `shared(for:)` returns.
        let engineC = SIDEngine.shared(for: session)
        XCTAssertTrue(engineB === engineC)

        engineB.unsubscribe(tokenB)
        // The *last* subscriber just left — the engine should have torn
        // itself down and removed itself from the shared registry, so
        // this call constructs a brand-new instance rather than
        // resurrecting the stopped one.
        let engineD = SIDEngine.shared(for: session)
        XCTAssertFalse(engineC === engineD)
    }


    @MainActor
    func testSIDEngineSupportsSubscribersWithDifferentNeedsSimultaneously() {
        // One subscriber needs only register writes (no synthesis, no
        // audio tap); another needs only the audio tap. Neither should
        // interfere with the other being able to subscribe/unsubscribe
        // independently.
        let session = DeviceSession(
            device: UltimateDevice(name: "SIDEngine Mixed Needs Test", host: "192.0.2.1"),
            settings: AppSettings())
        let engine = SIDEngine.shared(for: session)

        let registerToken = engine.subscribe(needs: SIDEngineNeeds(mode: .registerActivity)) {}
        let audioToken = engine.subscribe(needs: SIDEngineNeeds(mode: .spectrum)) {}

        engine.unsubscribe(registerToken)
        // The audio-tap subscriber is still active, so the engine must
        // not have torn itself down yet.
        XCTAssertTrue(SIDEngine.shared(for: session) === engine)

        engine.unsubscribe(audioToken)
        XCTAssertFalse(SIDEngine.shared(for: session) === engine)
    }


    func testSIDRegisterActivityRecordsWritesPerChipAndOffset() {
        var activity = SIDRegisterActivity(chipCount: 2)
        XCTAssertEqual(activity.lastWrite.count, 2)
        XCTAssertEqual(activity.lastWrite[0].count, SIDRegisterActivity.registerCount)
        XCTAssertTrue(activity.lastWrite[0].allSatisfy { $0 == nil })

        let now = Date()
        activity.record(chipIndex: 0, offset: 4, at: now) // V1 CTRL
        activity.record(chipIndex: 1, offset: 22, at: now) // RES/FILT

        XCTAssertEqual(activity.lastWrite[0][4], now)
        XCTAssertNil(activity.lastWrite[0][22])
        XCTAssertEqual(activity.lastWrite[1][22], now)

        // Out-of-range chip/offset are ignored rather than crashing.
        activity.record(chipIndex: 5, offset: 0, at: now)
        activity.record(chipIndex: 0, offset: 99, at: now)
    }


    func testSIDRegisterActivityMnemonicsCoverAllRegistersInOrder() {
        XCTAssertEqual(SIDRegisterActivity.mnemonics.count, SIDRegisterActivity.registerCount)
        XCTAssertEqual(SIDRegisterActivity.mnemonics.first, "V1 FREQ LO")
        XCTAssertEqual(SIDRegisterActivity.mnemonics[6], "V1 SR")
        XCTAssertEqual(SIDRegisterActivity.mnemonics[7], "V2 FREQ LO")
        XCTAssertEqual(SIDRegisterActivity.mnemonics.last, "MODE/VOL")
    }


    func testSIDVoiceLineupDetectsOnsetsOnGateAndPitchSlide() {
        var channel = SIDVoiceChannel(
            id: 0, chipIndex: 0, voiceIndex: 0, bufferSize: 8, noteHistoryLength: 6)

        func push(frequency: UInt16, gate: Bool) {
            channel.registers.write(offset: 0, value: UInt8(frequency & 0xFF))
            channel.registers.write(offset: 1, value: UInt8(frequency >> 8))
            channel.registers.write(offset: 4, value: gate ? 0x01 : 0x00)
            channel.pushNoteHistory()
        }

        push(frequency: 0x1000, gate: false) // index 0: silence, no onset
        push(frequency: 0x1000, gate: true)  // index 1: gate-on onset
        push(frequency: 0x1000, gate: true)  // index 2: same note held, no onset
        push(frequency: 0x1400, gate: true)  // index 3: slid to a clearly different pitch, onset
        push(frequency: 0x1400, gate: false) // index 4: gate off, no onset
        push(frequency: 0x1400, gate: false) // index 5: still off, no onset

        let onsets = SIDVoiceLineupView.onsets(for: channel)
        XCTAssertEqual(onsets.map(\.index), [1, 3])
    }


    func testSIDOscilloscopeGridLayoutPrefersFewerRowsOnWideScreens() {
        // 11 modes, wide screen: should fit in 2 rows (6 columns) since
        // 11/2 = 6 columns comfortably clears the minimum cell width.
        let (rows, columns) = SIDOscilloscopeWindowController.gridLayout(
            count: 11, screenWidth: 2400, minCellWidth: 300)
        XCTAssertEqual(rows, 2)
        XCTAssertEqual(columns, 6)
        XCTAssertGreaterThanOrEqual(rows * columns, 11)
    }


    func testSIDOscilloscopeGridLayoutFallsBackToMoreRowsOnNarrowScreens() {
        // Same 11 modes on a much narrower screen: 2 rows (6 columns)
        // would make each cell narrower than the minimum, so it should
        // fall back to more, narrower rows instead.
        let (rows, columns) = SIDOscilloscopeWindowController.gridLayout(
            count: 11, screenWidth: 900, minCellWidth: 300)
        XCTAssertGreaterThan(rows, 2)
        XCTAssertLessThanOrEqual(columns, 3)
        XCTAssertGreaterThanOrEqual(rows * columns, 11)
    }


    func testSIDOscilloscopeGridLayoutHandlesTrivialCounts() {
        XCTAssertEqual(SIDOscilloscopeWindowController.gridLayout(count: 0, screenWidth: 1920, minCellWidth: 300).rows, 0)
        let single = SIDOscilloscopeWindowController.gridLayout(count: 1, screenWidth: 1920, minCellWidth: 300)
        XCTAssertEqual(single.rows, 1)
        XCTAssertEqual(single.columns, 1)
    }


    func testSIDWindowLayoutStoreRoundTripsThroughUserDefaults() throws {
        let id = UUID()
        defer { SIDWindowLayoutStore.clear(for: id) }
        XCTAssertNil(SIDWindowLayoutStore.load(for: id))
        XCTAssertFalse(SIDWindowLayoutStore.hasSavedLayout(for: id))

        let entries = [
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.oscilloscope.rawValue,
                frame: CGRect(x: 10, y: 20, width: 300, height: 180)),
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.spectrum.rawValue,
                frame: CGRect(x: 320, y: 20, width: 300, height: 180)),
        ]
        let saved = SIDWindowLayoutSnapshot(entries: entries, savedAt: Date())
        SIDWindowLayoutStore.save(saved, for: id)

        XCTAssertTrue(SIDWindowLayoutStore.hasSavedLayout(for: id))
        let loaded = try XCTUnwrap(SIDWindowLayoutStore.load(for: id))
        XCTAssertEqual(loaded.entries, entries)
    }


    func testSIDWindowLayoutStoreTreatsEmptyEntriesAsNoSavedLayout() {
        let id = UUID()
        defer { SIDWindowLayoutStore.clear(for: id) }
        SIDWindowLayoutStore.save(SIDWindowLayoutSnapshot(entries: [], savedAt: Date()), for: id)
        // An explicitly-saved empty layout (e.g. saved while no SID
        // windows were open) still decodes fine, but shouldn't be
        // reported as "something to restore" — `restoreWindowLayout()`
        // treats it as a no-op.
        XCTAssertFalse(SIDWindowLayoutStore.hasSavedLayout(for: id))
        XCTAssertNotNil(SIDWindowLayoutStore.load(for: id))
    }


    func testSIDWindowLayoutStoreClearRemovesSavedLayout() {
        let id = UUID()
        let entries = [SIDWindowLayoutEntry(mode: "Oscilloscope", frame: .zero)]
        SIDWindowLayoutStore.save(SIDWindowLayoutSnapshot(entries: entries, savedAt: Date()), for: id)
        XCTAssertTrue(SIDWindowLayoutStore.hasSavedLayout(for: id))

        SIDWindowLayoutStore.clear(for: id)
        XCTAssertNil(SIDWindowLayoutStore.load(for: id))
        XCTAssertFalse(SIDWindowLayoutStore.hasSavedLayout(for: id))
    }


    func testSIDWindowLayoutStoreOverwritesExistingLayout() throws {
        let id = UUID()
        defer { SIDWindowLayoutStore.clear(for: id) }
        let original = [
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.oscilloscope.rawValue,
                frame: CGRect(x: 10, y: 20, width: 300, height: 180)),
        ]
        SIDWindowLayoutStore.save(
            SIDWindowLayoutSnapshot(entries: original, savedAt: Date(timeIntervalSince1970: 1)),
            for: id)

        let replacement = [
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.spectrum.rawValue,
                frame: CGRect(x: 40, y: 60, width: 400, height: 220)),
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.lissajous.rawValue,
                frame: CGRect(x: 450, y: 60, width: 400, height: 220)),
        ]
        SIDWindowLayoutStore.save(
            SIDWindowLayoutSnapshot(entries: replacement, savedAt: Date(timeIntervalSince1970: 2)),
            for: id)

        let loaded = try XCTUnwrap(SIDWindowLayoutStore.load(for: id))
        XCTAssertEqual(loaded.entries, replacement)
        XCTAssertEqual(loaded.savedAt, Date(timeIntervalSince1970: 2))
    }


    func testSIDSpectrumAnalyzerAutoGainAvoidsAllBarsPeggedAtMax() throws {
        let sampleRate = 48000.0
        let analyzer = SIDSpectrumAnalyzer(sampleRate: sampleRate)
        let toneHz = 1000.0

        var lastBars: [Float]?
        var phase = 0.0
        let totalSamples = SIDSpectrumAnalyzer.fftSize * 8
        var samples = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            samples[i] = Float(sin(phase))
            phase += 2 * Double.pi * toneHz / sampleRate
        }
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 256, samples.count)
            if let bars = analyzer.ingest(Array(samples[offset..<end])) {
                lastBars = bars
            }
            offset = end
        }

        let bars = try XCTUnwrap(lastBars)
        // A single pure tone should show a clear peak against a mostly-low
        // background, not a wall of maxed-out bars — an earlier fixed
        // "-60...0 dB" scale pegged nearly every bar to full-red
        // regardless of actual signal content, since the raw FFT
        // magnitude scale doesn't line up with that range.
        let peggedCount = bars.filter { $0 > 0.95 }.count
        XCTAssertLessThan(peggedCount, bars.count / 4)
    }


    func testSIDSpectrumAnalyzerReportsSilenceAsEmptyBarsNotAutoGainedNoise() throws {
        let analyzer = SIDSpectrumAnalyzer(sampleRate: 48000.0)

        // Genuine digital silence, plus the kind of tiny residual noise a
        // real audio path has even with nothing playing — the Ultimate
        // keeps streaming audio packets continuously whenever the stream
        // is running, whether or not anything is actually playing.
        // Auto-gain would otherwise rescale this relative to itself and
        // light up every bar exactly as if real music were loud.
        let totalSamples = SIDSpectrumAnalyzer.fftSize * 4
        var silence = [Float](repeating: 0, count: totalSamples)
        for i in silence.indices {
            // A tiny, deterministic "dither"-like wobble — well under
            // the silence threshold, but not literally all zeros.
            silence[i] = Float(sin(Double(i) * 0.7)) * 0.0002
        }

        var lastBars: [Float]?
        var offset = 0
        while offset < silence.count {
            let end = min(offset + 256, silence.count)
            if let bars = analyzer.ingest(Array(silence[offset..<end])) {
                lastBars = bars
            }
            offset = end
        }

        let bars = try XCTUnwrap(lastBars)
        XCTAssertTrue(bars.allSatisfy { $0 == 0 })
    }


    func testSIDNoteNameConversionMatchesStandardTuning() {
        XCTAssertEqual(SIDVoiceChannel.noteName(forHz: 440), "A4")
        XCTAssertEqual(SIDVoiceChannel.noteName(forHz: 261.63), "C4")
        XCTAssertEqual(SIDVoiceChannel.noteName(forHz: 0), "—")
        XCTAssertEqual(SIDVoiceChannel.midiNoteNumber(forHz: 440), 69)
        XCTAssertEqual(SIDVoiceChannel.midiNoteNumber(forHz: 261.63), 60)
        XCTAssertNil(SIDVoiceChannel.midiNoteNumber(forHz: 0))
    }


    func testSIDPianoKeyboardLayoutUsesFixedRange() {
        XCTAssertFalse(SIDPianoKeyboardLayout.isBlackKey(60)) // C4
        XCTAssertTrue(SIDPianoKeyboardLayout.isBlackKey(61))  // C#4
        XCTAssertEqual(SIDPianoKeyboardLayout.range.lowerBound % 12, 0)
        let whites = SIDPianoKeyboardLayout.whiteKeys()
        // C1…C7 is six full octaves of white keys plus the top C (7×6+1).
        XCTAssertEqual(whites.count, 43)
        XCTAssertEqual(whites.first, SIDPianoKeyboardLayout.minMidi) // C1
        XCTAssertEqual(whites.last, SIDPianoKeyboardLayout.maxMidi)  // C7
        XCTAssertTrue(SIDPianoKeyboardLayout.range.contains(96))
    }

    /// Covers the register read/write hex round-trip only — mode selection
    /// for the debug *stream* goes through `setConfigItem` (see
    /// `testMachineInputRequestAndServiceAutoEnable`/HANDOVER.md §14), not
    /// this register.


}
