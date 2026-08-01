import Foundation

/// Tracks how recently each of the SID's own actual writable registers
/// (per chip) was last touched — for the Register Activity Grid
/// visualization mode. This is a genuinely different signal from every
/// other SID Oscilloscope mode: all of them show *derived* audio state
/// reconstructed from register writes (a waveform, an envelope curve, a
/// filter response), never the write *activity* itself — which registers
/// the player routine is actually spending time touching, and how often.
struct SIDRegisterActivity {
    /// 7 registers per voice x 3 voices + 4 global filter/volume
    /// registers = 25 writable offsets per chip, relative to that chip's
    /// base address. (The remaining 4 addresses in the SID's 29-byte
    /// range, $D419-$D41C, are read-only — POTX/POTY/OSC3/ENV3 — and
    /// have no meaning as write activity.)
    static let registerCount = 25

    /// Mnemonic label for each of the 25 offsets, in address order —
    /// matches the field layout `SIDVoiceRegisters.write(offset:value:)`
    /// and `SIDFilterRegisters.write(offset:value:)` already use.
    static let mnemonics: [String] = {
        var names: [String] = []
        for voice in 1...3 {
            names.append("V\(voice) FREQ LO")
            names.append("V\(voice) FREQ HI")
            names.append("V\(voice) PW LO")
            names.append("V\(voice) PW HI")
            names.append("V\(voice) CTRL")
            names.append("V\(voice) AD")
            names.append("V\(voice) SR")
        }
        names.append("FC LO")
        names.append("FC HI")
        names.append("RES/FILT")
        names.append("MODE/VOL")
        return names
    }()

    /// Last-write timestamp for each of the 25 offsets, per chip — `nil`
    /// if never written since this instance was created.
    private(set) var lastWrite: [[Date?]]

    init(chipCount: Int) {
        lastWrite = Array(
            repeating: Array(repeating: nil, count: Self.registerCount),
            count: max(chipCount, 1))
    }

    /// Records a write to `offset` (0..<25, relative to the chip's base
    /// address — the same absolute numbering `mnemonics` uses) on
    /// `chipIndex`. Out-of-range values are ignored rather than
    /// crashing, matching the tolerance `SIDVoiceRegisters`/
    /// `SIDFilterRegisters` already have for unexpected offsets.
    mutating func record(chipIndex: Int, offset: Int, at time: Date) {
        guard lastWrite.indices.contains(chipIndex),
              (0..<Self.registerCount).contains(offset) else { return }
        lastWrite[chipIndex][offset] = time
    }
}
