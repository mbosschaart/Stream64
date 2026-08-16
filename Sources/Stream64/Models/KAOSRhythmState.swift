import Foundation

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
    var activeVoiceMask: UInt8 = 0
    var digiActivity: Float = 0
    var voiceLevels: [Float] = Array(repeating: 0, count: 6)

    private var smoothedEnergy: Float = 0
    private var lastBeatTime: TimeInterval?
    private var smoothedBeatInterval: TimeInterval?
    private var beatCount = 0

    /// Advances beat/phrase state at the engine UI cadence. `timestamp` is
    /// deliberately supplied so this is deterministic and unit-testable.
    mutating func advance(
        timestamp: TimeInterval,
        events: [Event],
        spectrumBars: [Float],
        channels: [SIDVoiceChannel]
    ) {
        let previousTime = lastBeatTime ?? timestamp
        let dt = max(0, min(0.2, timestamp - previousTime))
        let decayDt = max(dt, 1.0 / 30.0)
        beatPulse = max(0, beatPulse - Float(decayDt * 3.2))
        barStartPulse = max(0, barStartPulse - Float(decayDt * 3.6))
        phraseStartPulse = max(0, phraseStartPulse - Float(decayDt * 3.2))
        digiActivity = max(0, digiActivity - Float(decayDt * 1.25))

        bassEnergy = Self.mean(spectrumBars.prefix(8))
        midEnergy = Self.mean(spectrumBars.dropFirst(8).prefix(18))
        masterLevel = min(1, bassEnergy * 1.35 + midEnergy * 0.45)
        smoothedEnergy += (masterLevel - smoothedEnergy) * 0.08

        let registerEnergy = events.reduce(Float(0)) {
            max($0, $1.weight)
        }
        if events.contains(.digiVolumeStep) {
            digiActivity = 1
        }
        let trigger = max(registerEnergy, masterLevel)
        let threshold = max(0.14, smoothedEnergy * 1.28 + 0.035)
        let sinceBeat = timestamp - (lastBeatTime ?? -10)

        if trigger >= threshold, sinceBeat >= 0.18 {
            registerBeat(timestamp: timestamp, strength: trigger, measured: true)
        } else {
            // Once a pattern is confident, keep a clock running between
            // register events. This makes KAOS scenes and typography flow
            // through sparse/noisy productions instead of freezing.
            let interval = smoothedBeatInterval ?? 0.5
            if sinceBeat >= interval {
                registerBeat(
                    timestamp: timestamp,
                    strength: max(masterLevel, 0.28),
                    measured: false)
            }
            beatStrength += (masterLevel - beatStrength) * 0.1
            beatConfidence = max(0, beatConfidence - 0.002)
        }

        let activeInterval = smoothedBeatInterval ?? 0.5
        beatPhase = Float(min(1, max(0, timestamp - (lastBeatTime ?? timestamp)) / activeInterval))

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

    private mutating func registerBeat(
        timestamp: TimeInterval,
        strength: Float,
        measured: Bool
    ) {
        if let previous = lastBeatTime {
            let interval = timestamp - previous
            if measured, (0.26...1.0).contains(interval) {
                if let currentInterval = smoothedBeatInterval {
                    smoothedBeatInterval =
                        currentInterval + (interval - currentInterval) * 0.24
                } else {
                    smoothedBeatInterval = interval
                }
                if let smoothedBeatInterval {
                    inferredBPM = Float(
                        min(220, max(60, 60 / smoothedBeatInterval)))
                    beatConfidence = min(1, beatConfidence + 0.16)
                }
            } else if measured {
                beatConfidence = max(0, beatConfidence - 0.08)
            }
        }
        lastBeatTime = timestamp
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
    }

    private static func mean<C: Collection>(_ values: C) -> Float
    where C.Element == Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }
}
