import Foundation

/// Detects sustained chip inactivity from raw voice state, never from mirrored
/// presentation data or the count of repeated register writes.
struct SIDVisualMirrorDetector {
    static let inactivityDelay: TimeInterval = 5
    private var startedAt: TimeInterval?
    private var lastActive: [TimeInterval?] = [nil, nil]

    mutating func update(channels: [SIDVoiceChannel], filters: [SIDFilterRegisters],
                         at now: TimeInterval) -> Int? {
        guard channels.contains(where: { $0.chipIndex == 1 }), filters.count >= 2 else {
            self = Self()
            return nil
        }
        if startedAt == nil { startedAt = now }
        var active = [false, false]
        for channel in channels where (0..<2).contains(channel.chipIndex) {
            let chip = channel.chipIndex
            let filter = filters[chip]
            let registers = channel.registers
            let disconnected = channel.voiceIndex == 2 && filter.voice3Disconnected
            let waveform = registers.control & 0xf0 != 0
            let sounding = !registers.test && !disconnected && filter.volume > 0
                && waveform && channel.frequencyHz > 1
                && (registers.gate || channel.synth.envelope > 0.015)
            if sounding || channel.digiActivity > 0.05 { active[chip] = true }
        }
        for chip in 0..<2 where active[chip] { lastActive[chip] = now }
        // Resume real data immediately when both chips participate. Never
        // mirror a stale source into silence when neither chip is active.
        guard active[0] != active[1] else { return nil }
        let source = active[0] ? 0 : 1
        let destination = 1 - source
        let quietSince = lastActive[destination] ?? startedAt ?? now
        return now - quietSince >= Self.inactivityDelay ? source : nil
    }
}

/// Visual-only copies. Engine synthesis, raw register data and audio output
/// always retain real state. The destination keeps its SwiftUI/channel identity.
struct SIDVisualPresentation {
    var channels: [SIDVoiceChannel]
    var filters: [SIDFilterRegisters]
    var rhythm: KAOSRhythmState
    var registerActivity: SIDRegisterActivity

    static func supportsMirroring(_ mode: SIDVisualizationMode) -> Bool {
        if mode.isGenerative { return true }
        switch mode {
        case .kaos, .sidShowcase, .oscilloscope, .envelope, .mixerConsole,
             .pianoRoll, .pianoKeyboard, .voiceLineup, .vuMeterBank, .colorfulWaveform,
             .filterCurve, .adsrKnobs, .registerActivity, .pulseWidth:
            return true
        default:
            return false
        }
    }

    init(channels: [SIDVoiceChannel], filters: [SIDFilterRegisters], rhythm: KAOSRhythmState,
         source: Int?, enabled: Bool, mode: SIDVisualizationMode,
         registerActivity: SIDRegisterActivity = SIDRegisterActivity(chipCount: 1)) {
        self.channels = channels
        self.filters = filters
        self.rhythm = rhythm
        self.registerActivity = registerActivity
        guard enabled, Self.supportsMirroring(mode), let source, (0..<2).contains(source),
              filters.count >= 2 else { return }
        let destination = 1 - source
        self.registerActivity = registerActivity.visualCopy(source: source, destination: destination)
        for index in self.channels.indices where self.channels[index].chipIndex == destination {
            let target = self.channels[index]
            if let original = channels.first(where: { $0.chipIndex == source && $0.voiceIndex == target.voiceIndex }) {
                self.channels[index] = original.visualCopy(identity: target)
            }
        }
        self.filters[destination] = filters[source]
        for voice in 0..<3 {
            let from = source * 3 + voice, to = destination * 3 + voice
            if self.rhythm.voiceLevels.indices.contains(to), self.rhythm.voiceLevels.indices.contains(from) {
                self.rhythm.voiceLevels[to] = rhythm.voiceLevels[from]
            }
            let bit = UInt8(1 << to)
            self.rhythm.activeVoiceMask &= ~bit
            if rhythm.activeVoiceMask & UInt8(1 << from) != 0 { self.rhythm.activeVoiceMask |= bit }
        }
    }
}
