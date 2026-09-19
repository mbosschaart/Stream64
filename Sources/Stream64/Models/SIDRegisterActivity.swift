import Foundation

/// Per-chip write and value-change timestamps for the 25 writable SID bytes.
/// Repeated writes remain observable without disguising unchanged registers
/// as musical changes. Every decoded write is compared, even within one tick.
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

    private(set) var lastChange: [[Date?]]
    private(set) var values: [[UInt8?]]

    init(chipCount: Int) {
        lastWrite = Array(
            repeating: Array(repeating: nil, count: Self.registerCount),
            count: max(chipCount, 1))
        lastChange = lastWrite
        values = Array(repeating: Array(repeating: nil, count: Self.registerCount),
                       count: max(chipCount, 1))
    }

    func selecting(chips: [Int]) -> Self {
        var copy = self
        let valid = chips.filter { lastWrite.indices.contains($0) }
        copy.lastWrite = valid.map { lastWrite[$0] }
        copy.lastChange = valid.map { lastChange[$0] }
        copy.values = valid.map { values[$0] }
        return copy
    }

    /// Preserve timestamps so mirrored write/change flashes decay in sync.
    /// Only the returned display copy is changed; raw trace data stays intact.
    func visualCopy(source: Int, destination: Int) -> Self {
        guard lastWrite.indices.contains(source), lastWrite.indices.contains(destination) else { return self }
        var copy = self
        copy.lastWrite[destination] = lastWrite[source]
        copy.lastChange[destination] = lastChange[source]
        copy.values[destination] = values[source]
        return copy
    }

    /// A first observed byte also flashes; subsequent identical values do not.
    /// Records a write to `offset` (0..<25, relative to the chip's base
    /// address — the same absolute numbering `mnemonics` uses) on
    /// `chipIndex`. Out-of-range values are ignored rather than
    /// crashing, matching the tolerance `SIDVoiceRegisters`/
    /// `SIDFilterRegisters` already have for unexpected offsets.
    mutating func record(chipIndex: Int, offset: Int, value: UInt8? = nil, at time: Date) {
        guard lastWrite.indices.contains(chipIndex),
              (0..<Self.registerCount).contains(offset) else { return }
        lastWrite[chipIndex][offset] = time
        if let value {
            if values[chipIndex][offset] != value {
                lastChange[chipIndex][offset] = time
            }
            values[chipIndex][offset] = value
        }
    }
    /// Brief write indication stays truthful under frame-by-frame refreshes;
    /// only changed bytes retrigger the brighter, longer foreground pulse.
    func intensity(chipIndex: Int, offset: Int, at now: Date, changes: Bool) -> Double {
        guard lastWrite.indices.contains(chipIndex),
              (0..<Self.registerCount).contains(offset),
              let timestamp = (changes ? lastChange : lastWrite)[chipIndex][offset] else { return 0 }
        let age = now.timeIntervalSince(timestamp)
        let duration = changes ? 0.22 : 0.10
        guard age >= 0, age < duration else { return 0 }
        return pow(1 - age / duration, 2)
    }
}
