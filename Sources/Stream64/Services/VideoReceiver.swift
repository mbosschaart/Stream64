import Foundation
import Network

/// Receives the Ultimate 64 VIC video stream over UDP and assembles frames.
///
/// Packet layout (little endian), per the Ultimate data streams spec:
///   u16 sequence, u16 frame, u16 line (bit 15 = last packet of frame),
///   u16 pixelsPerLine, u8 linesPerPacket, u8 bitsPerPixel, u16 encoding,
///   followed by pixel data (4bpp packed, low nibble = left pixel).
///
/// Frame size follows the machine's video standard:
///   • PAL  — 384×272 (~50 Hz)
///   • NTSC — 384×240 (~60 Hz)
final class VideoReceiver {
    static let width = 384
    /// Largest stream height the Ultimate emits (PAL). Used for buffer sizing
    /// and packet range checks; published frames may be shorter (NTSC).
    static let maxHeight = 272
    static let palHeight = 272
    static let ntscHeight = 240
    /// Backward-compatible alias for callers that mean “max buffer height”.
    static let height = maxHeight

    /// Called with a fully assembled frame: one byte per pixel (palette index 0-15),
    /// row-major, `width * frameHeight` bytes (272 PAL or 240 NTSC).
    var onFrame: ((Data) -> Void)?
    var onStats: ((_ fps: Double) -> Void)?

    /// Lifetime packet count for this receiver instance. Connection pickup
    /// snapshots a baseline and looks for increases; the value deliberately
    /// survives listener restarts. Written on the receive queue; racy reads
    /// from other threads are fine for polling.
    private var packetCount = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "video-receiver")
    private let connectionsLock = NSLock()
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    // Frame assembly state (accessed only on `queue`).
    private var frameBuffer = [UInt8](repeating: 0, count: width * maxHeight)
    private var receivedLines = [Bool](repeating: false, count: maxHeight)
    private var assemblingFrameID: UInt16?
    private var assemblingSequence: UInt16?
    private var frameCount = 0
    private var lastStatsTime = DispatchTime.now()

    var packetsReceived: Int {
        queue.sync { packetCount }
    }

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

    // Debug instrumentation (enabled with UV_DEBUG=1).
    private static let debug = ProcessInfo.processInfo.environment["UV_DEBUG"] == "1"
    private var dbgPackets = 0
    private var dbgRejected = 0
    private var dbgFrames = 0

    static func isStructurallyValidPacket(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data.withUnsafeBytes { raw in
            let lineField = UInt16(raw[4]) | (UInt16(raw[5]) << 8)
            let startLine = Int(lineField & 0x7FFF)
            let pixelsPerLine = Int(
                UInt16(raw[6]) | (UInt16(raw[7]) << 8))
            let linesPerPacket = Int(raw[8])
            let bitsPerPixel = Int(raw[9])
            let encoding = UInt16(raw[10]) | (UInt16(raw[11]) << 8)
            return bitsPerPixel == 4
                && pixelsPerLine == Self.width
                && linesPerPacket > 0
                && encoding == 0
                && data.count >= 12
                    + pixelsPerLine * linesPerPacket / 2
                && startLine + linesPerPacket <= Self.maxHeight
        }
    }

    /// True for the Ultimate's documented stream heights (PAL / NTSC).
    static func isSupportedFrameHeight(_ height: Int) -> Bool {
        height == palHeight || height == ntscHeight
    }

    /// Internal for deterministic packet-assembly tests. Production callers
    /// invoke it only from the receiver's serial queue.
    func ingest(_ data: Data) {
        guard Self.isStructurallyValidPacket(data) else {
            if Self.debug { dbgRejected += 1 }
            return
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let sequence = UInt16(raw[0]) | (UInt16(raw[1]) << 8)
            let frameID = UInt16(raw[2]) | (UInt16(raw[3]) << 8)
            let lineField = UInt16(raw[4]) | (UInt16(raw[5]) << 8)
            let lastPacket = (lineField & 0x8000) != 0
            let startLine = Int(lineField & 0x7FFF)
            let pixelsPerLine = Int(UInt16(raw[6]) | (UInt16(raw[7]) << 8))
            let linesPerPacket = Int(raw[8])

            if assemblingFrameID != frameID {
                beginFrame(id: frameID, sequence: sequence)
            } else if let previousSequence = assemblingSequence,
                      !isForwardOrSame(sequence, after: previousSequence) {
                // A late/out-of-order packet from this frame is safe to
                // ignore: newer rows already won, and it must not roll the
                // assembler back to stale content.
                return
            }
            assemblingSequence = sequence

            packetCount += 1
            if Self.debug {
                dbgPackets += 1
                if dbgPackets % 500 == 1 {
                    NSLog(
                        "[video] packets=%d rejected=%d frames=%d len=%d",
                        dbgPackets, dbgRejected, dbgFrames, data.count)
                }
            }
            let payloadBytes = pixelsPerLine * linesPerPacket / 2

            // Unpack 4bpp: low nibble first.
            var dst = startLine * Self.width
            var src = 12
            for _ in 0..<(payloadBytes) {
                let byte = raw[src]
                frameBuffer[dst] = byte & 0x0F
                frameBuffer[dst + 1] = byte >> 4
                dst += 2
                src += 1
            }
            for line in startLine..<(startLine + linesPerPacket) {
                receivedLines[line] = true
            }

            if lastPacket {
                // Height is implied by the last packet's end line. PAL ends
                // at 272; NTSC at 240. Require every line in that range —
                // not the full 272-slot buffer — or NTSC never publishes.
                let frameHeight = startLine + linesPerPacket
                let complete = Self.isSupportedFrameHeight(frameHeight)
                    && (0..<frameHeight).allSatisfy({ receivedLines[$0] })
                if complete {
                    if Self.debug { dbgFrames += 1 }
                    publishFrame(height: frameHeight)
                } else if Self.debug {
                    dbgRejected += 1
                }
                assemblingFrameID = nil
                assemblingSequence = nil
            }
        }
    }

    private func beginFrame(id: UInt16, sequence: UInt16) {
        assemblingFrameID = id
        assemblingSequence = sequence
        receivedLines.withUnsafeMutableBufferPointer {
            $0.update(repeating: false)
        }
    }

    /// Wrap-aware sequence ordering. The sender's next datagram is normally
    /// `previous + 1`; accept forward gaps (the missing rows will prevent
    /// publish) but discard packets more than half the UInt16 range behind.
    private func isForwardOrSame(
        _ sequence: UInt16,
        after previous: UInt16
    ) -> Bool {
        let delta = sequence &- previous
        return delta == 0 || delta < 0x8000
    }

    private func publishFrame(height: Int) {
        let byteCount = Self.width * height
        let frame = Data(frameBuffer[0..<byteCount])
        onFrame?(frame)

        frameCount += 1
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastStatsTime.uptimeNanoseconds) / 1_000_000_000
        if elapsed >= 1.0 {
            onStats?(Double(frameCount) / elapsed)
            frameCount = 0
            lastStatsTime = now
        }
    }
}
