import Foundation

/// Presentation-only fallback when a game/demo has no SID header. Time advances
/// only with continuous trace delivery; silence in a missing stream is not proof.
struct SIDLiveActivityDetector {
    static let learningSeconds = 4.0
    static let retirementSeconds = 30.0
    private struct Chip {
        var bytes = [UInt8](repeating: 0, count: 25)
        var volumeKnown = false
        var musicalWrite = false
        var evidenceTicks = 0
        var volumeChanges = 0
        var lastEvidence = -Double.infinity
        var confirmed = false

        var sustaining: Bool {
            guard !volumeKnown || bytes[24] & 15 > 0 else { return false }
            return (0..<3).contains { voice in
                let o = voice * 7, control = bytes[o + 4]
                return control & 1 != 0 && control & 8 == 0 && control & 0xF0 != 0
                    && (bytes[o] != 0 || bytes[o + 1] != 0)
            }
        }
    }
    private var chips: [Chip]
    private var observedTime = 0.0
    private var lastUpdate: TimeInterval?
    private var previousTraceHealthy = false
    private var initialEvidenceTime: Double?
    private(set) var activeChips: [Int]?

    init(chipCount: Int) { chips = Array(repeating: Chip(), count: max(0, chipCount)) }

    mutating func record(chip: Int, offset: Int, value: UInt8) {
        guard chips.indices.contains(chip), (0..<25).contains(offset) else { return }
        let changed = chips[chip].bytes[offset] != value
        let wasSustaining = chips[chip].sustaining
        if offset == 24 {
            if chips[chip].volumeKnown, chips[chip].bytes[24] & 15 != value & 15 {
                chips[chip].volumeChanges += 1
            }
            chips[chip].volumeKnown = true
        }
        chips[chip].bytes[offset] = value
        if changed && (wasSustaining || chips[chip].sustaining) {
            chips[chip].musicalWrite = true
        }
    }

    mutating func advance(at time: TimeInterval, traceReceived: Bool, traceHealthy: Bool) {
        let elapsed = lastUpdate.map { max(0, time - $0) } ?? 0
        lastUpdate = time
        // Large scheduling gaps are also unobserved, even if a batch arrived.
        let continuous = traceReceived && traceHealthy && previousTraceHealthy && elapsed <= 0.5
        previousTraceHealthy = traceReceived && traceHealthy
        if continuous { observedTime += elapsed }
        for i in chips.indices {
            // Sustained oscillator state needs no further writes. Multiple
            // volume steps identify digi playback; a one-off init/mute does not.
            let evidence = traceReceived && (chips[i].sustaining || chips[i].musicalWrite || chips[i].volumeChanges >= 4)
            chips[i].volumeChanges = 0
            chips[i].musicalWrite = false
            if evidence {
                chips[i].evidenceTicks += 1
                chips[i].lastEvidence = observedTime
                if chips[i].evidenceTicks >= 3 {
                    chips[i].confirmed = true
                    if initialEvidenceTime == nil { initialEvidenceTime = observedTime }
                }
            } else if observedTime - chips[i].lastEvidence > 0.5 {
                chips[i].evidenceTicks = 0
            }
        }
        guard let start = initialEvidenceTime, observedTime - start >= Self.learningSeconds else { return }
        let candidates = chips.indices.filter {
            chips[$0].confirmed && observedTime - chips[$0].lastEvidence < Self.retirementSeconds
        }
        // Global silence cannot identify a new topology. Keep the last layout.
        if !candidates.isEmpty { activeChips = candidates }
    }
}
