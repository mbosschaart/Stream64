import Foundation

/// A live 64K-address activity map for the debug bus-trace: for every
/// possible address, the timestamp of its most recent read and write.
/// Feeds the real-time memory-map heatmap view — bright on access, fading
/// to black over `MemoryMapView.fadeDuration`.
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

    func record(_ entries: [DebugStreamEntry]) {
        let now = CFAbsoluteTimeGetCurrent()
        for entry in entries {
            let index = Int(entry.address)
            if entry.isRead {
                lastRead[index] = now
            } else {
                lastWrite[index] = now
            }
        }
    }

    func reset() {
        lastRead = [Double](repeating: 0, count: Self.addressSpace)
        lastWrite = [Double](repeating: 0, count: Self.addressSpace)
    }
}
