import Foundation

/// File metadata takes precedence over the live fallback: a quiet chip in a
/// known multi-SID tune remains part of its declared topology.
enum SIDVisualizationAdaptation: String, CaseIterable, Identifiable {
    case automatic = "Auto (SID file)"
    case singleSID = "Force single SID"
    case hardware = "Show all configured SIDs"
    var id: String { rawValue }
    var displayName: String { self == .automatic ? "Auto (SID file or live activity)" : rawValue }
}

/// Session-local metadata. Generation checks prevent late uploads from restoring
/// stale metadata after a reset or a newer playback request.
struct SIDPlaybackMetadata: Equatable {
    private(set) var addresses: [UInt16]?
    private(set) var generation = UUID()

    @discardableResult
    mutating func beginPlayback() -> UUID {
        generation = UUID()
        addresses = nil
        return generation
    }

    mutating func didStart(addresses: [UInt16]?, generation: UUID) {
        guard generation == self.generation else { return }
        self.addresses = addresses
    }
}

/// Maps arbitrary chip counts. Three voices per chip is a SID hardware property;
/// neither the source count nor the destination count is fixed to dual SID.
struct SIDVisualTopology {
    let activeChips: [Int]
    let configuredChipCount: Int

    init(configuredAddresses: [UInt16], tuneAddresses: [UInt16]?,
         adaptation: SIDVisualizationAdaptation, liveActiveChips: [Int]? = nil) {
        configuredChipCount = configuredAddresses.count
        switch adaptation {
        case .hardware:
            activeChips = Array(configuredAddresses.indices)
        case .singleSID:
            activeChips = configuredAddresses.isEmpty ? [] : [0]
        case .automatic:
            if let tuneAddresses, !tuneAddresses.isEmpty {
                let matches = configuredAddresses.indices.filter { tuneAddresses.contains(configuredAddresses[$0]) }
                activeChips = matches.isEmpty ? Array(configuredAddresses.indices) : matches
            } else if let liveActiveChips {
                let valid = configuredAddresses.indices.filter { liveActiveChips.contains($0) }
                activeChips = valid.isEmpty ? Array(configuredAddresses.indices) : valid
            } else {
                activeChips = Array(configuredAddresses.indices)
            }
        }
    }

    func sourceChip(for destination: Int) -> Int {
        guard !activeChips.isEmpty else { return destination }
        return activeChips.contains(destination) ? destination : activeChips[destination % activeChips.count]
    }
}

/// Display copies only; engine registers, audio and debug traces stay real.
struct SIDVisualPresentation {
    var channels: [SIDVoiceChannel]
    var filters: [SIDFilterRegisters]
    var rhythm: KAOSRhythmState
    var registerActivity: SIDRegisterActivity
    var displayedChipIndices: [Int]
    var chipCount: Int { displayedChipIndices.count }

    static func isInstrument(_ mode: SIDVisualizationMode) -> Bool {
        switch mode {
        case .oscilloscope, .envelope, .mixerConsole, .pianoRoll, .pianoKeyboard,
             .voiceLineup, .vuMeterBank, .registerActivity, .adsrKnobs, .pulseWidth,
             .controlBits, .dashboard, .filterCurve:
            return true
        default: return false
        }
    }

    init(channels: [SIDVoiceChannel], filters: [SIDFilterRegisters], rhythm: KAOSRhythmState,
         topology: SIDVisualTopology, mode: SIDVisualizationMode,
         registerActivity: SIDRegisterActivity) {
        self.channels = channels
        self.filters = filters
        self.rhythm = rhythm
        self.registerActivity = registerActivity
        displayedChipIndices = Array(0..<topology.configuredChipCount)
        if Self.isInstrument(mode) {
            displayedChipIndices = topology.activeChips
            self.channels = channels.filter { topology.activeChips.contains($0.chipIndex) }
            self.filters = topology.activeChips.compactMap { filters.indices.contains($0) ? filters[$0] : nil }
            self.registerActivity = registerActivity.selecting(chips: topology.activeChips)
            return
        }
        for destination in 0..<topology.configuredChipCount {
            let source = topology.sourceChip(for: destination)
            guard source != destination else { continue }
            for index in self.channels.indices where self.channels[index].chipIndex == destination {
                let target = self.channels[index]
                if let original = channels.first(where: { $0.chipIndex == source && $0.voiceIndex == target.voiceIndex }) {
                    self.channels[index] = original.visualCopy(identity: target)
                }
            }
            if filters.indices.contains(source), self.filters.indices.contains(destination) {
                self.filters[destination] = filters[source]
            }
            for voice in 0..<3 {
                let from = source * 3 + voice, to = destination * 3 + voice
                if self.rhythm.voiceLevels.count <= to {
                    self.rhythm.voiceLevels += Array(repeating: 0, count: to + 1 - self.rhythm.voiceLevels.count)
                }
                self.rhythm.voiceLevels[to] = rhythm.voiceLevels.indices.contains(from) ? rhythm.voiceLevels[from] : 0
                guard from < UInt16.bitWidth, to < UInt16.bitWidth else { continue }
                let bit = UInt16(1 << to)
                self.rhythm.activeVoiceMask &= ~bit
                if rhythm.activeVoiceMask & UInt16(1 << from) != 0 { self.rhythm.activeVoiceMask |= bit }
            }
        }
    }
}
