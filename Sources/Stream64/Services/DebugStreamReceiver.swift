import Foundation
import Network

/// Receives the Ultimate debug bus-trace stream (6510/VIC/1541 cycle trace)
/// over UDP and decodes it into `DebugStreamEntry` records.
///
/// Packet layout: u16 sequence, u16 reserved, then up to 360 32-bit trace
/// words (all little-endian). See `DebugStreamEntry` for the per-word bit
/// layout. This mirrors the shape of `VideoReceiver`/`AudioReceiver`: an
/// `NWListener`-based UDP receiver with `start(port:)`/`stop()` and a
/// lifetime packet counter used by `DeviceSession` to detect an
/// already-running stream.
final class DebugStreamReceiver {
    /// Which source the currently-running stream should be decoded as.
    /// Changing this takes effect on the next received packet — set it
    /// before calling `start(port:)`.
    private var sourceValue: DebugStreamSource = .cpu6510
    var source: DebugStreamSource {
        get { onReceiverQueue ? sourceValue : queue.sync { sourceValue } }
        set {
            if onReceiverQueue {
                sourceValue = newValue
            } else {
                queue.sync { sourceValue = newValue }
            }
        }
    }

    /// Multiple windows can watch the same trace at once (e.g. the Debug
    /// Trace table/memory-map and the SID Oscilloscope), so entries/stats
    /// are multicast to every registered observer rather than a single
    /// closure — one window's `stop()` must not silently cut off another's
    /// feed. Fires on the receiver's private queue; callers hop to the
    /// main actor themselves, same convention as
    /// `VideoReceiver.onFrame`/`AudioReceiver`.
    private var entryObservers: [UUID: ([DebugStreamEntry]) -> Void] = [:]
    private var statsObservers: [UUID: (Double) -> Void] = [:]

    /// Register to receive decoded entries. Returns a token to pass to
    /// `removeEntriesObserver(_:)` when done — always remove it (e.g. when
    /// a window closes) or the closure (and whatever it captures) leaks
    /// for the receiver's lifetime.
    @discardableResult
    func addEntriesObserver(_ observer: @escaping ([DebugStreamEntry]) -> Void) -> UUID {
        let id = UUID()
        queue.async { [weak self] in self?.entryObservers[id] = observer }
        return id
    }

    func removeEntriesObserver(_ id: UUID) {
        queue.async { [weak self] in self?.entryObservers.removeValue(forKey: id) }
    }

    @discardableResult
    func addStatsObserver(_ observer: @escaping (Double) -> Void) -> UUID {
        let id = UUID()
        queue.async { [weak self] in self?.statsObservers[id] = observer }
        return id
    }

    func removeStatsObserver(_ id: UUID) {
        queue.async { [weak self] in self?.statsObservers.removeValue(forKey: id) }
    }

    /// Lifetime packet count for this receiver instance, used the same way
    /// as `VideoReceiver.packetsReceived`/`AudioReceiver.packetsReceived`:
    /// callers snapshot a baseline and look for increases to detect an
    /// already-running stream. Written on the receive queue; racy reads
    /// from other threads are fine for polling.
    private var packetCount = 0

    /// Packet-sequence gaps observed since `start(port:)` — a rough
    /// "dropped packets" indicator surfaced in the trace window.
    private var missedPacketCount = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "debug-stream-receiver")
    private let queueKey = DispatchSpecificKey<Void>()
    private let connectionsLock = NSLock()
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    private var wordCount = 0
    private var lastStatsTime = DispatchTime.now()
    private var lastSequence: UInt16?

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    private var onReceiverQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    var packetsReceived: Int {
        onReceiverQueue ? packetCount : queue.sync { packetCount }
    }

    var missedPackets: Int {
        onReceiverQueue ? missedPacketCount : queue.sync { missedPacketCount }
    }

    // Raw-bytes capture for file export: the concatenated packet payloads
    // (sequence/reserved header stripped), matching the layout that the
    // official `grab_debug.py`/`dump_bus_trace.c` tooling already consumes.
    private var captureBuffer = Data()
    private var capturing = false
    private static let maxCaptureBytes = 64 * 1024 * 1024 // ~64 MB safety cap

    func start(port: UInt16) throws {
        stop()
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.register(connection)
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock()
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        connectionsLock.unlock()
        for connection in connections {
            connection.cancel()
        }
        queue.async { [weak self] in
            self?.lastSequence = nil
            self?.missedPacketCount = 0
        }
    }

    /// Begin (or restart) an in-memory capture of raw packet payloads,
    /// later retrieved with `stopCaptureAndExportData(_:)`. Bounded to
    /// `maxCaptureBytes`; further bytes are silently dropped rather than
    /// growing unbounded during a long trace.
    func startCapture() {
        queue.async { [weak self] in
            self?.captureBuffer.removeAll(keepingCapacity: true)
            self?.capturing = true
        }
    }

    func stopCaptureAndExportData(_ completion: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            let data = self?.captureBuffer ?? Data()
            self?.capturing = false
            DispatchQueue.main.async { completion(data) }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection,
                  self.isActive(connection) else { return }
            if let data {
                self.ingest(data)
            }
            if error == nil {
                self.receive(on: connection)
            } else {
                self.unregister(connection)
            }
        }
    }

    private func register(_ connection: NWConnection) {
        connectionsLock.lock()
        activeConnections[ObjectIdentifier(connection)] = connection
        connectionsLock.unlock()
    }

    private func unregister(_ connection: NWConnection) {
        connectionsLock.lock()
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        connectionsLock.unlock()
    }

    private func isActive(_ connection: NWConnection) -> Bool {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return activeConnections[ObjectIdentifier(connection)] === connection
    }

    /// Internal packet entry point, kept separate for deterministic sequence
    /// accounting tests. Production calls it only from the receiver queue.
    func ingest(_ data: Data) {
        guard data.count >= 4 else { return }
        packetCount += 1

        // `ingest` is normally called by the receiver queue. Read the
        // queue-confined value directly in that case; calling the public
        // synchronized getter here would synchronously dispatch onto this
        // same queue and trigger libdispatch's self-deadlock trap.
        let (sequence, entries) = DebugStreamEntry.parsePacket(
            data, source: onReceiverQueue ? sourceValue : source)
        if let lastSequence {
            let delta = sequence &- lastSequence
            if delta > 1, delta < 0x8000 {
                // Count the actual forward gap. Duplicates and packets that
                // arrive late/out of order are not missing packets.
                missedPacketCount += Int(delta) - 1
            }
        }
        lastSequence = sequence

        if capturing, captureBuffer.count < Self.maxCaptureBytes {
            captureBuffer.append(data.dropFirst(4))
        }

        wordCount += entries.count
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastStatsTime.uptimeNanoseconds) / 1_000_000_000
        if elapsed >= 1.0 {
            let rate = Double(wordCount) / elapsed
            for observer in statsObservers.values { observer(rate) }
            wordCount = 0
            lastStatsTime = now
        }

        guard !entries.isEmpty else { return }
        for observer in entryObservers.values { observer(entries) }
    }
}
