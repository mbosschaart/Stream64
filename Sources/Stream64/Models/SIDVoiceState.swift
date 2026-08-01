import Foundation

/// Decoded register state for one SID voice (7 consecutive registers).
/// Written from `DebugStreamEntry` writes the oscilloscope observes on
/// the debug bus-trace stream — there is no way to read individual-voice
/// state off the wire otherwise; the Ultimate's audio stream is only the
/// final post-mix stereo output.
struct SIDVoiceRegisters: Equatable {
    var frequency: UInt16 = 0
    /// 12-bit; only the low 12 bits of the 16-bit value are meaningful.
    var pulseWidth: UInt16 = 0
    /// GATE|SYNC|RING|TEST|TRIANGLE|SAWTOOTH|PULSE|NOISE, bit 0 upward.
    var control: UInt8 = 0
    /// Attack in bits 4-7, Decay in bits 0-3.
    var attackDecay: UInt8 = 0
    /// Sustain in bits 4-7, Release in bits 0-3.
    var sustainRelease: UInt8 = 0

    var gate: Bool { control & 0x01 != 0 }
    var syncEnabled: Bool { control & 0x02 != 0 }
    var ringModEnabled: Bool { control & 0x04 != 0 }
    var test: Bool { control & 0x08 != 0 }
    var triangleEnabled: Bool { control & 0x10 != 0 }
    var sawtoothEnabled: Bool { control & 0x20 != 0 }
    var pulseEnabled: Bool { control & 0x40 != 0 }
    var noiseEnabled: Bool { control & 0x80 != 0 }

    var attack: Int { Int(attackDecay >> 4) }
    var decay: Int { Int(attackDecay & 0x0F) }
    /// 0-15 (fraction of full scale, not yet divided by 15).
    var sustain: Int { Int(sustainRelease >> 4) }
    var release: Int { Int(sustainRelease & 0x0F) }

    /// Write one byte at `offset` (0-6) within this voice's register
    /// block. Out-of-range offsets are ignored — callers pass whatever
    /// offset the address decode produced, which for a mirrored/aliased
    /// address could technically land anywhere.
    mutating func write(offset: Int, value: UInt8) {
        switch offset {
        case 0: frequency = (frequency & 0xFF00) | UInt16(value)
        case 1: frequency = (frequency & 0x00FF) | (UInt16(value) << 8)
        case 2: pulseWidth = (pulseWidth & 0x0F00) | UInt16(value)
        case 3: pulseWidth = (pulseWidth & 0x00FF) | (UInt16(value & 0x0F) << 8)
        case 4: control = value
        case 5: attackDecay = value
        case 6: sustainRelease = value
        default: break
        }
    }
}

/// Standard, widely-published SID ADSR rate → time-in-milliseconds
/// tables (from the original datasheet, reproduced in essentially every
/// SID emulator/reference). Used here as exponential time constants (see
/// `SIDVoiceSynth.stepEnvelope`) rather than a cycle-exact reproduction of
/// the real chip's rate-counter/exponential-divisor hardware — visually
/// very close, not bit-exact.
enum SIDTiming {
    static let attackMilliseconds: [Double] = [
        2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000,
    ]
    static let decayReleaseMilliseconds: [Double] = [
        6, 24, 48, 72, 114, 168, 204, 240, 300, 750, 1500, 2400, 3000, 9000, 15000, 24000,
    ]
}

/// Runtime oscillator + envelope state for one voice, advanced forward in
/// time by the oscilloscope's synthesis loop from register writes alone.
///
/// This is **not** a cycle-exact SID emulation — there is no audio
/// feedback to check it against, only the goal of a live waveform that
/// looks and behaves like the real thing closely enough to be useful for
/// debugging (is this voice gated, what waveform, roughly what pitch,
/// does the envelope shape look right). Specific simplifications:
/// - Combined waveforms (e.g. pulse+triangle) average the active
///   generators rather than reproducing the real chip's undocumented
///   digital-AND-like combination logic.
/// - Ring modulation approximates the real "XOR the two voices'
///   accumulator MSBs before the triangle generator" behavior using the
///   *previous* step's neighbor phase (one step of lag, not a fully
///   simultaneous solve).
/// - Oscillator hard sync (the `SYNC` control bit) is decoded and can be
///   displayed, but is not applied to the synthesized waveform — doing so
///   correctly needs the neighbor voice's wrap *event*, not just its
///   phase, which would require restructuring the per-voice stepping into
///   a single ordered pass across all voices for a real gain in accuracy.
/// - The noise generator is a 23-bit LFSR re-clocked at a fixed multiple
///   of the oscillator frequency — a texture/pitch approximation, not a
///   verified match to the real generator's exact tap positions.
struct SIDVoiceSynth {
    /// SID's own clock. Only affects the frequency-register-to-Hz
    /// conversion; the Ultimate emulates PAL timing by default.
    static let clockHz = 985_248.0

    private(set) var phase: Double = 0     // 0..<1
    private(set) var envelope: Double = 0  // 0...1
    private var envelopePhase: EnvelopePhase = .release
    private var lfsr: UInt32 = 0x7F_FFFF
    private var noiseStepPhase: Double = 0
    private var noiseSample: Double = 0

    private enum EnvelopePhase {
        case attack, decaySustain, release
    }

    /// Short label for the UI (Mixer Console mode) — "A"/"D"/"S"/"R".
    /// Decay and Sustain share one internal phase (the real chip has no
    /// separate "sustain" state; it's just decay that stopped moving once
    /// it reached the sustain level), so this distinguishes them for
    /// display by checking whether the envelope has actually settled at
    /// the target `sustainLevel` (0...1) yet.
    func envelopeStageLabel(sustainLevel: Double) -> String {
        switch envelopePhase {
        case .attack: return "A"
        case .decaySustain: return abs(envelope - sustainLevel) < 0.02 ? "S" : "D"
        case .release: return "R"
        }
    }

    /// Advance by `dt` seconds and return the resulting sample in
    /// -1...1 (envelope-scaled). `neighborPhase` is the previous step's
    /// phase of the voice this one ring-modulates against (voice 1 ←
    /// voice 3, voice 2 ← voice 1, voice 3 ← voice 2, circularly).
    mutating func step(dt: Double, registers: SIDVoiceRegisters, neighborPhase: Double) -> Double {
        stepEnvelope(dt: dt, registers: registers)
        return stepOscillator(dt: dt, registers: registers, neighborPhase: neighborPhase)
    }

    private mutating func stepEnvelope(dt: Double, registers: SIDVoiceRegisters) {
        if registers.gate {
            if envelopePhase == .release { envelopePhase = .attack }
            switch envelopePhase {
            case .attack:
                let tau = max(SIDTiming.attackMilliseconds[registers.attack], 0.5) / 1000
                envelope += (1 - envelope) * (1 - exp(-dt / tau))
                if envelope > 0.995 {
                    envelope = 1
                    envelopePhase = .decaySustain
                }
            case .decaySustain:
                let tau = max(SIDTiming.decayReleaseMilliseconds[registers.decay], 0.5) / 1000
                let sustainLevel = Double(registers.sustain) / 15
                envelope += (sustainLevel - envelope) * (1 - exp(-dt / tau))
            case .release:
                break
            }
        } else {
            envelopePhase = .release
            let tau = max(SIDTiming.decayReleaseMilliseconds[registers.release], 0.5) / 1000
            envelope += (0 - envelope) * (1 - exp(-dt / tau))
        }
    }

    private mutating func stepOscillator(
        dt: Double, registers: SIDVoiceRegisters, neighborPhase: Double
    ) -> Double {
        guard !registers.test else {
            phase = 0 // TEST holds the accumulator at zero.
            return 0
        }

        let hz = Double(registers.frequency) * Self.clockHz / 16_777_216
        phase += hz * dt
        phase -= phase.rounded(.down)

        var sum = 0.0
        var activeCount = 0
        if registers.triangleEnabled {
            var t = phase < 0.5 ? (4 * phase - 1) : (3 - 4 * phase)
            if registers.ringModEnabled, (phase >= 0.5) != (neighborPhase >= 0.5) {
                t = -t
            }
            sum += t
            activeCount += 1
        }
        if registers.sawtoothEnabled {
            sum += 2 * phase - 1
            activeCount += 1
        }
        if registers.pulseEnabled {
            let duty = Double(registers.pulseWidth) / 4095
            sum += phase < duty ? 1 : -1
            activeCount += 1
        }
        if registers.noiseEnabled {
            stepNoise(dt: dt, hz: hz)
            sum += noiseSample
            activeCount += 1
        }
        guard activeCount > 0 else { return 0 }
        return (sum / Double(activeCount)) * envelope
    }

    /// Sample-and-hold pseudo-noise from a 23-bit LFSR, re-clocked at a
    /// fixed multiple of the oscillator frequency — see the type-level
    /// doc comment for the accuracy caveat.
    private mutating func stepNoise(dt: Double, hz: Double) {
        noiseStepPhase += hz * dt * 16
        guard noiseStepPhase >= 1 else { return }
        noiseStepPhase -= noiseStepPhase.rounded(.down)
        let bit0 = ((lfsr >> 22) ^ (lfsr >> 17)) & 1
        lfsr = ((lfsr << 1) | bit0) & 0x7F_FFFF
        let byte =
            (((lfsr >> 20) & 1) << 7) | (((lfsr >> 18) & 1) << 6) | (((lfsr >> 15) & 1) << 5)
            | (((lfsr >> 12) & 1) << 4) | (((lfsr >> 10) & 1) << 3) | (((lfsr >> 6) & 1) << 2)
            | (((lfsr >> 3) & 1) << 1) | (lfsr & 1)
        noiseSample = Double(byte) / 127.5 - 1
    }
}
