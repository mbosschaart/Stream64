import Foundation

/// A live 64K-address activity map for the debug bus-trace: for every
/// possible address, the timestamp of its most recent read and write, plus
/// the byte value last seen there. Feeds `MemoryMapView`'s two
/// visualizations — "I/O Fade" (bright on access, fading to black over
/// `MemoryMapView.fadeDuration`) and "Byte Load" (brightness by the address's
/// current byte value instead of by recency).
///
/// Written directly from `DebugStreamReceiver`'s private queue (very high
/// frequency — up to roughly a million entries/second). Renderers consume
/// immutable snapshots. Snapshot copies run **outside** the writer lock:
/// under the lock we only retain Array headers (CoW share); element copies
/// happen after unlock, and the next `record`/`reset` uniquifies writer
/// storage via copy-on-write instead of stalling the UDP path.
final class MemoryHeatmap {
    static let addressSpace = 65536

    struct RenderSnapshot {
        let generation: UInt64
        let lastAccess: [Double]
        let lastAccessWasRead: [Bool]
        let lastValue: [UInt8]
    }

    struct AddressState {
        let lastRead: Double
        let lastWrite: Double
        let lastAccess: Double
        let lastAccessWasRead: Bool
        let lastValue: UInt8
    }

    private let lock = NSLock()
    private var generationValue: UInt64 = 0

    /// `CFAbsoluteTimeGetCurrent()` of the most recent read/write to this
    /// address; 0 means never accessed since the last `reset()`.
    private var lastRead = [Double](repeating: 0, count: addressSpace)
    private var lastWrite = [Double](repeating: 0, count: addressSpace)

    /// Timestamp and direction of the most recent access of either kind.
    /// These are deliberately stored explicitly rather than inferred by
    /// comparing `lastRead` and `lastWrite`: several accesses in one packet
    /// can share a timestamp, and timestamp nudges used to break those ties
    /// can extend slightly into the next packet's time window. Either case
    /// can leave a just-read byte orange after a preceding write. Updating
    /// this direction bit for every entry preserves the exact bus order.
    private var lastAccess = [Double](repeating: 0, count: addressSpace)
    private var lastAccessWasRead = [Bool](repeating: true, count: addressSpace)

    /// The byte value seen in the most recent read or write to this
    /// address — feeds `MemoryMapView`'s "Byte Load" visualization
    /// (brightness by value rather than by recency). Meaningless at an
    /// address that's never been touched (still 0, same as never-accessed);
    /// callers distinguish that case with `lastRead`/`lastWrite`, same as
    /// the recency-based visualization already has to.
    private var lastValue = [UInt8](repeating: 0, count: addressSpace)

    /// Reads/writes to the *same* address within one call are common —
    /// read-modify-write instructions (`INC`/`ASL`/`ROL`/etc.) always read
    /// then write the same address. `lastAccessWasRead` is assigned for
    /// every entry, so the final access in real array/bus order wins without
    /// relying on timestamp comparison or floating-point tie breaking.
    func record(_ entries: [DebugStreamEntry]) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        generationValue &+= 1
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

    /// Cheap generation sample for renderers that only need to know whether
    /// data changed since the last full snapshot — avoids a ~650 KB copy on
    /// every timer tick.
    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    /// Publishes an immutable renderer snapshot. The writer lock is held only
    /// long enough to sample the generation and retain Array headers; the
    /// ~650 KB element copies happen after unlock so `record()` is not stalled
    /// for the duration of the memcpy.
    func renderSnapshot() -> RenderSnapshot {
        lock.lock()
        let generation = generationValue
        let access = lastAccess
        let directions = lastAccessWasRead
        let values = lastValue
        lock.unlock()

        return RenderSnapshot(
            generation: generation,
            lastAccess: access.withUnsafeBufferPointer { Array($0) },
            lastAccessWasRead: directions.withUnsafeBufferPointer { Array($0) },
            lastValue: values.withUnsafeBufferPointer { Array($0) })
    }

    func state(at address: Int) -> AddressState? {
        guard (0..<Self.addressSpace).contains(address) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return AddressState(
            lastRead: lastRead[address],
            lastWrite: lastWrite[address],
            lastAccess: lastAccess[address],
            lastAccessWasRead: lastAccessWasRead[address],
            lastValue: lastValue[address])
    }

    func reset() {
        lock.lock()
        generationValue &+= 1
        lastRead.withUnsafeMutableBufferPointer {
            $0.update(repeating: 0)
        }
        lastWrite.withUnsafeMutableBufferPointer {
            $0.update(repeating: 0)
        }
        lastAccess.withUnsafeMutableBufferPointer {
            $0.update(repeating: 0)
        }
        lastAccessWasRead.withUnsafeMutableBufferPointer {
            $0.update(repeating: true)
        }
        lastValue.withUnsafeMutableBufferPointer {
            $0.update(repeating: 0)
        }
        lock.unlock()
    }
}
