import Foundation

/// All beat evidence collected during one bounded engine tick. Keeping this
/// separate from the published rhythm state makes evidence collection cheap
/// and lets the clock use raw FFT values rather than auto-gained display bars.
struct KAOSRhythmEvidence {
    var events: [KAOSRhythmState.Event] = []
    var spectrum: SIDSpectrumFeatures = .silence
    var spectrumBars: [Float] = []
}

/// Compact, shared music state for KAOS. Register events supply musical
/// structure while post-mix spectrum energy supplies reliable pulse for
/// digi/noise-heavy SID productions.
struct KAOSRhythmState: Equatable {
    enum Event: Equatable {
        case gateRise
        case frequencyChange
        case waveformChange
        case digiVolumeStep

        var weight: Float {
            switch self {
            case .gateRise: return 1.0
            case .frequencyChange: return 0.24
            case .waveformChange: return 0.45
            case .digiVolumeStep: return 0.8
            }
        }
    }

    var beatPulse: Float = 0
    /// Immediate transient response. This is deliberately independent of
    /// `beatPulse`: rapid fills can hit the visuals without destabilizing the
    /// tempo clock.
    var impactPulse: Float = 0
    var impactStrength: Float = 0
    var beatStrength: Float = 0
    var beatPhase: Float = 0
    var barStartPulse: Float = 0
    var phraseStartPulse: Float = 0
    var bassEnergy: Float = 0
    var midEnergy: Float = 0
    var masterLevel: Float = 0
    var inferredBPM: Float = 0
    var beatConfidence: Float = 0
    var barPhase = 0
    var phraseIndex = 0
    var sceneIndex = 0
    var activeVoiceMask: UInt8 = 0
    var digiActivity: Float = 0
    var voiceLevels: [Float] = Array(repeating: 0, count: 6)

    private var smoothedEnergy: Float = 0
    private var lastUpdateTime: TimeInterval?
    private var lastClockBeatTime: TimeInterval?
    private var lastOnsetTime: TimeInterval?
    private var smoothedBeatInterval: TimeInterval = 0.5
    private var fluxMean: Float = 0
    private var fluxDeviation: Float = 0
    private var lowMean: Float = 0
    private var lowDeviation: Float = 0
    private var beatCount = 0

    /// Advances beat/phrase state at the engine UI cadence. `timestamp` is
    /// deliberately supplied so this is deterministic and unit-testable.
    mutating func advance(
        timestamp: TimeInterval,
        events: [Event],
        spectrumBars: [Float],
        channels: [SIDVoiceChannel]
    ) {
        advance(
            timestamp: timestamp,
            evidence: KAOSRhythmEvidence(events: events, spectrumBars: spectrumBars),
            channels: channels)
    }

    mutating func advance(
        timestamp: TimeInterval,
        evidence: KAOSRhythmEvidence,
        channels: [SIDVoiceChannel]
    ) {
        let dt = max(0, min(0.2, timestamp - (lastUpdateTime ?? timestamp)))
        lastUpdateTime = timestamp
        let decayDt = max(dt, 1.0 / 30.0)
        beatPulse = max(0, beatPulse - Float(decayDt * 2.7))
        impactPulse = max(0, impactPulse - Float(decayDt * 7.5))
        barStartPulse = max(0, barStartPulse - Float(decayDt * 3.6))
        phraseStartPulse = max(0, phraseStartPulse - Float(decayDt * 3.2))
        digiActivity = max(0, digiActivity - Float(decayDt * 1.25))

        bassEnergy = Self.mean(evidence.spectrumBars.prefix(8))
        midEnergy = Self.mean(evidence.spectrumBars.dropFirst(8).prefix(18))
        masterLevel = min(1, bassEnergy * 1.35 + midEnergy * 0.45)
        smoothedEnergy += (masterLevel - smoothedEnergy) * 0.08

        let registerEnergy = evidence.events.reduce(Float(0)) {
            max($0, $1.weight)
        }
        if evidence.events.contains(.digiVolumeStep) {
            digiActivity = 1
        }
        let audioImpact = updateAudioOnset(evidence.spectrum)
        let impact = max(registerEnergy, audioImpact)
        if impact > 0 {
            impactPulse = 1
            impactStrength = impact
        }

        // The onset path only nudges a clock when it lands close to its
        // expected grid. Off-grid fills remain responsive impacts but cannot
        // drag scene changes or BPM around.
        if impact >= 0.5,
           timestamp - (lastOnsetTime ?? -.infinity) >= 0.09 {
            acceptOnset(timestamp: timestamp, strength: impact)
        }
        advanceClock(to: timestamp)
        beatStrength += (masterLevel - beatStrength) * 0.08
        beatConfidence = max(0, beatConfidence - Float(dt) * 0.012)
        beatPhase = Float(min(
            1, max(0, timestamp - (lastClockBeatTime ?? timestamp)) / smoothedBeatInterval))

        activeVoiceMask = 0
        voiceLevels = Array(
            channels.prefix(6).map {
                let active = $0.registers.gate || $0.registers.noiseEnabled
                return active ? max($0.levelRMS, $0.peakLevel * 0.45) : 0
            })
        for channel in channels.prefix(6) {
            if channel.registers.gate || channel.registers.noiseEnabled {
                activeVoiceMask |= UInt8(1 << channel.id)
            }
        }
        if voiceLevels.count < 6 {
            voiceLevels += Array(repeating: 0, count: 6 - voiceLevels.count)
        }
    }

    private mutating func updateAudioOnset(_ features: SIDSpectrumFeatures) -> Float {
        guard features.rms > 0 else { return 0 }
        let fluxDelta = features.spectralFlux - fluxMean
        let lowDelta = features.lowBandEnergy - lowMean
        fluxMean += fluxDelta * 0.055
        lowMean += lowDelta * 0.055
        fluxDeviation += (abs(fluxDelta) - fluxDeviation) * 0.055
        lowDeviation += (abs(lowDelta) - lowDeviation) * 0.055
        let fluxZ = max(0, fluxDelta / max(fluxDeviation * 2.4, 0.02))
        let lowZ = max(0, lowDelta / max(lowDeviation * 2.8, 0.02))
        // Flux catches percussion/noise; low-band growth favors kick drums.
        return min(1, fluxZ * 0.64 + lowZ * 0.36)
    }

    private mutating func acceptOnset(timestamp: TimeInterval, strength: Float) {
        defer { lastOnsetTime = timestamp }
        guard let previousOnset = lastOnsetTime else {
            if lastClockBeatTime == nil {
                registerClockBeat(timestamp: timestamp, strength: strength, measured: true)
            }
            return
        }
        let interval = timestamp - previousOnset
        guard (0.28...0.95).contains(interval) else { return }
        let nearestMultiple = max(1, (interval / smoothedBeatInterval).rounded())
        let candidate = interval / nearestMultiple
        guard (0.30...0.86).contains(candidate) else { return }
        let error = abs(candidate - smoothedBeatInterval) / smoothedBeatInterval
        guard error < 0.28 || beatConfidence < 0.18 else { return }
        smoothedBeatInterval += (candidate - smoothedBeatInterval) * 0.12
        inferredBPM = Float(min(200, max(70, 60 / smoothedBeatInterval)))
        beatConfidence = min(1, beatConfidence + 0.13)

        if let lastClockBeatTime,
           abs(timestamp - lastClockBeatTime) <= smoothedBeatInterval * 0.24 {
            registerClockBeat(timestamp: timestamp, strength: strength, measured: true)
        }
    }

    private mutating func advanceClock(to timestamp: TimeInterval) {
        guard let lastClockBeatTime else { return }
        // A bounded loop absorbs a briefly delayed main run loop without
        // publishing an unbounded catch-up sequence after a sleep/wake.
        var beatTime = lastClockBeatTime
        var emitted = 0
        while timestamp - beatTime >= smoothedBeatInterval, emitted < 2 {
            beatTime += smoothedBeatInterval
            registerClockBeat(
                timestamp: beatTime,
                strength: max(masterLevel, 0.28),
                measured: false)
            emitted += 1
        }
    }

    private mutating func registerClockBeat(
        timestamp: TimeInterval,
        strength: Float,
        measured: Bool
    ) {
        lastClockBeatTime = timestamp
        beatPulse = 1
        beatStrength = strength
        beatCount += 1
        barPhase = beatCount % 4
        if barPhase == 0 {
            barStartPulse = 1
        }
        if beatCount.isMultiple(of: 16) {
            phraseIndex += 1
            phraseStartPulse = 1
        }
        sceneIndex = beatCount / 8
        if inferredBPM == 0 {
            inferredBPM = Float(60 / smoothedBeatInterval)
        }
    }

    private static func mean<C: Collection>(_ values: C) -> Float
    where C.Element == Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }
}
