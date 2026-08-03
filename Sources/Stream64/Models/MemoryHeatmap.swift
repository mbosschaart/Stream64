import Foundation

/// A live 64K-address activity map for the debug bus-trace: for every
/// possible address, the timestamp of its most recent read and write, plus
/// the byte value last seen there. Feeds `MemoryMapView`'s two
/// visualizations — "I/O Fade" (bright on access, fading to black over
/// `MemoryMapView.fadeDuration`) and "Byte Load" (brightness by the address's
/// current byte value instead of by recency).
///
/// Written directly from `DebugStreamReceiver`'s private queue (very high
/// frequency — up to roughly a million entries/second) and read racily
/// from the main actor at render time. This is the same "simple per-slot
/// writes can tear harmlessly" convention `VideoReceiver.packetsReceived`
/// already uses elsewhere in this codebase — a torn timestamp read just
/// means one pixel's fade is off by a fraction of a frame, invisible at
/// the render throttle `MemoryMapView` uses.
final class MemoryHeatmap {
    static let addressSpace = 65536

    /// `CFAbsoluteTimeGetCurrent()` of the most recent read/write to this
    /// address; 0 means never accessed since the last `reset()`.
    private(set) var lastRead = [Double](repeating: 0, count: addressSpace)
    private(set) var lastWrite = [Double](repeating: 0, count: addressSpace)

    /// Timestamp and direction of the most recent access of either kind.
    /// These are deliberately stored explicitly rather than inferred by
    /// comparing `lastRead` and `lastWrite`: several accesses in one packet
    /// can share a timestamp, and timestamp nudges used to break those ties
    /// can extend slightly into the next packet's time window. Either case
    /// can leave a just-read byte orange after a preceding write. Updating
    /// this direction bit for every entry preserves the exact bus order.
    private(set) var lastAccess = [Double](repeating: 0, count: addressSpace)
    private(set) var lastAccessWasRead = [Bool](repeating: true, count: addressSpace)

    /// The byte value seen in the most recent read or write to this
    /// address — feeds `MemoryMapView`'s "Byte Load" visualization
    /// (brightness by value rather than by recency). Meaningless at an
    /// address that's never been touched (still 0, same as never-accessed);
    /// callers distinguish that case with `lastRead`/`lastWrite`, same as
    /// the recency-based visualization already has to.
    private(set) var lastValue = [UInt8](repeating: 0, count: addressSpace)

    /// Reads/writes to the *same* address within one call are common —
    /// read-modify-write instructions (`INC`/`ASL`/`ROL`/etc.) always read
    /// then write the same address. `lastAccessWasRead` is assigned for
    /// every entry, so the final access in real array/bus order wins without
    /// relying on timestamp comparison or floating-point tie breaking.
    func record(_ entries: [DebugStreamEntry]) {
        let now = CFAbsoluteTimeGetCurrent()
        for entry in entries {
            let address = Int(entry.address)
            if entry.isRead {
                lastRead[address] = now
            } else {
                lastWrite[address] = now
            }
            lastAccess[address] = now
            lastAccessWasRead[address] = entry.isRead
            lastValue[address] = entry.data
        }
    }

    func reset() {
        lastRead = [Double](repeating: 0, count: Self.addressSpace)
        lastWrite = [Double](repeating: 0, count: Self.addressSpace)
        lastAccess = [Double](repeating: 0, count: Self.addressSpace)
        lastAccessWasRead = [Bool](repeating: true, count: Self.addressSpace)
        lastValue = [UInt8](repeating: 0, count: Self.addressSpace)
    }
}
