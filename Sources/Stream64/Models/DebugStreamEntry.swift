import Foundation

/// Which physical bus the current debug-stream word was captured from.
/// Selected (indirectly) by the `DebugStreamMode` written to the U64 debug
/// register before starting the stream.
enum DebugStreamSource: String, CaseIterable, Identifiable {
    case cpu6510 = "6510"
    case vic = "VIC"
    case drive1541 = "1541"
    var id: String { rawValue }
}

/// The debug-stream trace mode. Selected via the config item
/// `Data Streams / Debug Stream Mode` (`PUT
/// /v1/configs/Data%20Streams/Debug%20Stream%20Mode?value=<rawValue>`) —
/// **not** the debug register ($D7FF), despite that register also existing
/// and also being U64-only. This was confirmed against a real Ultimate
/// 64-II on firmware 3.15: `GET /v1/configs/Data%20Streams` returns a
/// `"Debug Stream Mode"` item whose `values` list is exactly this enum's
/// raw values (plus two modes newer than the public docs describe — see
/// `cpu6510WithIEC`/`cpu6510AndVicWithIEC`). An earlier version of this
/// code guessed the debug register controlled mode selection; live testing
/// showed writing arbitrary values there had zero effect on the captured
/// stream, which is what led to finding the real config item.
enum DebugStreamMode: String, CaseIterable, Identifiable {
    case cpu6510Only = "6510 Only"
    case vicOnly = "VIC Only"
    case cpu6510AndVic = "6510 & VIC"
    case drive1541Only = "1541 Only"
    case cpu6510AndDrive1541 = "6510 & 1541"
    /// Confirmed present on firmware 3.15 but not documented publicly.
    /// Presumed to add IEC bus signals (ATN/CLOCK/DATA) to the 6510-only
    /// word layout, the same way the 1541 layout already does — unverified.
    case cpu6510WithIEC = "6510 w/IEC"
    /// As above, combined with VIC cycles.
    case cpu6510AndVicWithIEC = "6510 & VIC w/IEC"
    var id: String { rawValue }

    /// The trace source(s) that can appear in a stream started in this mode.
    var sources: Set<DebugStreamSource> {
        switch self {
        case .cpu6510Only, .cpu6510WithIEC: return [.cpu6510]
        case .vicOnly: return [.vic]
        case .cpu6510AndVic, .cpu6510AndVicWithIEC: return [.cpu6510, .vic]
        case .drive1541Only: return [.drive1541]
        case .cpu6510AndDrive1541: return [.cpu6510, .drive1541]
        }
    }

    /// Which `DebugStreamSource` bit layout the live decoded table should
    /// use for this mode. 6510 and VIC cycles share an identical word
    /// layout (only their *classification* as a CPU vs. VIC cycle differs,
    /// via PHI2+BA — this app does not yet disambiguate that), so any
    /// 6510/VIC-only or combined mode decodes correctly with either.
    ///
    /// A combined 6510+1541 trace interleaves two structurally different
    /// word layouts with no per-word tag identifying which is which —
    /// decoding that live is a known limitation (Ultimate's own
    /// documentation calls this whole format "preliminary"). Use raw
    /// export + the official GtkWave tooling for that mode instead of the
    /// live table.
    var decodeSource: DebugStreamSource {
        switch self {
        case .cpu6510Only, .cpu6510AndVic, .cpu6510AndDrive1541,
             .cpu6510WithIEC, .cpu6510AndVicWithIEC:
            return .cpu6510
        case .vicOnly: return .vic
        case .drive1541Only: return .drive1541
        }
    }
}

/// One decoded 32-bit debug-stream cycle/access record. See the "Debug
/// Stream" section of
/// https://1541u-documentation.readthedocs.io/en/latest/data_streams.html
/// for the bit layout this decodes:
///
///   6510/VIC: PHI2|GAME#|EXROM#|BA|IRQ#|ROM#|NMI#|R/W#|Data(8)|Address(16)
///   1541:     '0' |ATN  |DATA  |CLOCK|SYNC|BYTE_READY|IRQ#|R/W#|Data(8)|Address(16)
struct DebugStreamEntry: Equatable {
    let source: DebugStreamSource
    let raw: UInt32
    let address: UInt16
    let data: UInt8
    let isRead: Bool

    /// PHI2 phase during the access. Always false for a 1541 entry — bit
    /// 31 is a fixed zero there.
    let phi2: Bool

    // MARK: 6510 / VIC flags — meaningless on a `.drive1541` entry.
    //
    // GAME#/EXROM#/IRQ#/ROM#/NMI# are active-*low* signals on the real
    // cartridge bus, but these properties store the raw bus level from the
    // word (true = line high = NOT asserted, false = line low = asserted).
    // Check `!entry.irq` etc. to ask "is this signal asserted".
    let game: Bool
    let exrom: Bool
    let ba: Bool
    let irq: Bool
    let rom: Bool
    let nmi: Bool

    // MARK: 1541 flags — meaningless on a `.cpu6510`/`.vic` entry.
    let atn: Bool
    let dataLine: Bool
    let clock: Bool
    let sync: Bool
    let byteReady: Bool

    init(word: UInt32, source: DebugStreamSource) {
        self.raw = word
        self.source = source
        self.address = UInt16(word & 0xFFFF)
        self.data = UInt8((word >> 16) & 0xFF)
        self.isRead = (word >> 24) & 0x1 != 0
        switch source {
        case .cpu6510, .vic:
            phi2 = (word >> 31) & 0x1 != 0
            nmi = (word >> 25) & 0x1 != 0
            rom = (word >> 26) & 0x1 != 0
            irq = (word >> 27) & 0x1 != 0
            ba = (word >> 28) & 0x1 != 0
            exrom = (word >> 29) & 0x1 != 0
            game = (word >> 30) & 0x1 != 0
            atn = false
            dataLine = false
            clock = false
            sync = false
            byteReady = false
        case .drive1541:
            phi2 = false
            irq = (word >> 25) & 0x1 != 0
            byteReady = (word >> 26) & 0x1 != 0
            sync = (word >> 27) & 0x1 != 0
            clock = (word >> 28) & 0x1 != 0
            dataLine = (word >> 29) & 0x1 != 0
            atn = (word >> 30) & 0x1 != 0
            game = false
            exrom = false
            ba = false
            rom = false
            nmi = false
        }
    }

    /// Decode one UDP debug-stream packet: a 16-bit sequence number + a
    /// reserved 16-bit word, followed by up to 360 32-bit trace words — all
    /// little-endian, matching the sequence-number encoding the format doc
    /// specifies. Malformed/short packets decode to an empty entry list
    /// rather than throwing, since stray UDP noise on the port must not
    /// crash the receiver.
    static func parsePacket(
        _ packet: Data, source: DebugStreamSource
    ) -> (sequence: UInt16, entries: [DebugStreamEntry]) {
        guard packet.count >= 4 else { return (0, []) }
        return packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let sequence = UInt16(raw[0]) | (UInt16(raw[1]) << 8)
            var entries: [DebugStreamEntry] = []
            entries.reserveCapacity((packet.count - 4) / 4)
            var offset = 4
            while offset + 4 <= packet.count {
                let word = UInt32(raw[offset])
                    | (UInt32(raw[offset + 1]) << 8)
                    | (UInt32(raw[offset + 2]) << 16)
                    | (UInt32(raw[offset + 3]) << 24)
                entries.append(DebugStreamEntry(word: word, source: source))
                offset += 4
            }
            return (sequence, entries)
        }
    }
}
