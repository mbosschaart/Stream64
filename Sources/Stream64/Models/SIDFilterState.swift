import Foundation

/// Decoded state of one chip's global filter/volume registers (offsets
/// 21-24 relative to the chip base — `$D415-$D418` for a chip at `$D400`).
/// Not decoded at all before the Filter Curve visualization mode; separate
/// from `SIDVoiceRegisters` because these four registers are per-*chip*,
/// not per-voice.
struct SIDFilterRegisters: Equatable {
    /// Only the low 3 bits are meaningful (bits 3-7 unused on real
    /// hardware).
    var cutoffLo: UInt8 = 0
    var cutoffHi: UInt8 = 0
    /// Bits 4-7 = resonance (0-15); bits 0-3 = which voices/external input
    /// are routed through the filter.
    var resonanceRouting: UInt8 = 0
    /// Bits 0-3 = master volume (0-15); bits 4-6 = LP/BP/HP select
    /// (independently combinable); bit 7 = voice 3 disconnected from the
    /// final output entirely (a classic trick to use voice 3 purely as an
    /// unheard modulation source for ring mod/sync on voice 1).
    var modeVolume: UInt8 = 0

    /// 11-bit cutoff value (0...2047) — not itself a frequency; see
    /// `SIDFilterRegisters.approximateCutoffHz(_:)` for the (approximate)
    /// Hz conversion.
    var cutoffValue: Int { (Int(cutoffHi) << 3) | Int(cutoffLo & 0x07) }
    var resonance: Int { Int(resonanceRouting >> 4) } // 0...15
    var externalRouted: Bool { resonanceRouting & 0x08 != 0 }
    var volume: Int { Int(modeVolume & 0x0F) } // 0...15
    var lowPassEnabled: Bool { modeVolume & 0x10 != 0 }
    var bandPassEnabled: Bool { modeVolume & 0x20 != 0 }
    var highPassEnabled: Bool { modeVolume & 0x40 != 0 }
    var voice3Disconnected: Bool { modeVolume & 0x80 != 0 }

    /// Whether `voice` (0, 1, or 2) is routed through the filter.
    func voiceRouted(_ voice: Int) -> Bool {
        guard voice >= 0, voice < 3 else { return false }
        return resonanceRouting & (1 << voice) != 0
    }

    mutating func write(offset: Int, value: UInt8) {
        switch offset {
        case 0: cutoffLo = value
        case 1: cutoffHi = value
        case 2: resonanceRouting = value
        case 3: modeVolume = value
        default: break
        }
    }

    /// Rough, widely-used approximation mapping the 11-bit cutoff value to
    /// an actual frequency. The real SID's cutoff curve is chip-specific
    /// (6581 vs. 8580), non-linear, and not officially published by
    /// Commodore/MOS — this is a smooth curve from ~30 Hz to ~12 kHz used
    /// only to give the Filter Curve visualization a plausible shape, not
    /// a claim of matching either real chip's actual response.
    static func approximateCutoffHz(_ cutoffValue: Int) -> Double {
        let t = Double(max(0, min(2047, cutoffValue))) / 2047.0
        return 30 + t * t * (12_000 - 30)
    }
}
