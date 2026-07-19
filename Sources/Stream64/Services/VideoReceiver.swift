import Foundation
import Network

/// Receives the Ultimate 64 VIC video stream over UDP and assembles frames.
///
/// Packet layout (little endian), per the Ultimate data streams spec:
///   u16 sequence, u16 frame, u16 line (bit 15 = last packet of frame),
///   u16 pixelsPerLine, u8 linesPerPacket, u8 bitsPerPixel, u16 encoding,
///   followed by pixel data (4bpp packed, low nibble = left pixel).
final class VideoReceiver {
    static let width = 384
    static let height = 272

    /// Called with a fully assembled frame: one byte per pixel (palette index 0-15),
    /// row-major, width*height bytes.
    var onFrame: ((Data) -> Void)?
    var onStats: ((_ fps: Double) -> Void)?

    /// Total packets received since start() — cheap liveness signal for
    /// "is a stream already arriving?" checks. Written on the receive
    /// queue; racy reads from other threads are fine for polling.
    private(set) var packetsReceived: Int = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "video-receiver")

    // Frame assembly state (accessed only on `queue`).
    private var frameBuffer = [UInt8](repeating: 0, count: width * height)
    private var frameCount = 0
    private var lastStatsTime = DispatchTime.now()

    func start(port: UInt16) throws {
        stop()
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self else { return }
            if let data {
                self.handlePacket(data)
            }
            if error == nil, let connection {
                self.receive(on: connection)
            }
        }
    }

    // Debug instrumentation (enabled with UV_DEBUG=1).
    private static let debug = ProcessInfo.processInfo.environment["UV_DEBUG"] == "1"
    private var dbgPackets = 0
    private var dbgRejected = 0
    private var dbgFrames = 0

    private func handlePacket(_ data: Data) {
        packetsReceived += 1
        if Self.debug {
            dbgPackets += 1
            if dbgPackets % 500 == 1 {
                NSLog("[video] packets=%d rejected=%d frames=%d len=%d", dbgPackets, dbgRejected, dbgFrames, data.count)
            }
        }
        guard data.count >= 12 else { return }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let lineField = UInt16(raw[4]) | (UInt16(raw[5]) << 8)
            let lastPacket = (lineField & 0x8000) != 0
            let startLine = Int(lineField & 0x7FFF)
            let pixelsPerLine = Int(UInt16(raw[6]) | (UInt16(raw[7]) << 8))
            let linesPerPacket = Int(raw[8])
            let bitsPerPixel = Int(raw[9])

            guard bitsPerPixel == 4, pixelsPerLine == Self.width,
                  data.count >= 12 + pixelsPerLine * linesPerPacket / 2,
                  startLine + linesPerPacket <= Self.height else {
                if Self.debug {
                    dbgRejected += 1
                    if dbgRejected % 100 == 1 {
                        NSLog("[video] REJECT ppl=%d lpp=%d bpp=%d line=%d len=%d", pixelsPerLine, linesPerPacket, bitsPerPixel, startLine, data.count)
                    }
                }
                return
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

            if lastPacket {
                if Self.debug { dbgFrames += 1 }
                publishFrame()
            }
        }
    }

    private func publishFrame() {
        let frame = Data(frameBuffer)
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
