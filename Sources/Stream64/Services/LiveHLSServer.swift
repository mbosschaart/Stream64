import Foundation
import Network

/// Bounded in-memory audio-only HLS origin. The random path token prevents
/// unrelated LAN clients from guessing stream URLs; no content is persisted.
final class LiveHLSServer {
    struct MediaSegment: Equatable {
        let sequence: Int
        let duration: Double
        let data: Data
        let discontinuity: Bool
    }

    enum ServerError: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "No routable local IPv4 address is available."
            case .failed(let message):
                return "AirPlay media server failed: \(message)"
            }
        }
    }

    private let queue = DispatchQueue(label: "stream64.airplay.hls.server")
    private let lock = NSLock()
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let maximumSegments: Int
    private var listener: NWListener?
    private var initializationSegment: Data?
    private var segments: [MediaSegment] = []
    private var nextSequence = 0
    private var completionDelivered = false

    init(maximumSegments: Int = 10) {
        self.maximumSegments = max(3, maximumSegments)
    }

    func start(
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard listener == nil else { return }
        guard let host = LocalNetwork.primaryIPv4Address() else {
            completion(.failure(ServerError.unavailable))
            return
        }

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !self.completionDelivered,
                          let port = listener.port,
                          let url = URL(string:
                            "http://\(host):\(port.rawValue)/\(self.token)/stream.m3u8")
                    else { return }
                    self.completionDelivered = true
                    completion(.success(url))
                case .failed(let error):
                    guard !self.completionDelivered else { return }
                    self.completionDelivered = true
                    completion(.failure(
                        ServerError.failed(error.localizedDescription)))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            completion(.failure(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        initializationSegment = nil
        segments.removeAll()
        nextSequence = 0
        lock.unlock()
    }

    func setInitializationSegment(_ data: Data) {
        lock.lock()
        initializationSegment = data
        lock.unlock()
    }

    var mediaSegmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return segments.count
    }

    var hasInitializationSegment: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initializationSegment != nil
    }

    /// Initialization + first media fragment forms a readable fragmented MP4
    /// for AVFoundation validation tests.
    func firstPlayableFragment() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard var data = initializationSegment,
              let segment = segments.first else { return nil }
        data.append(segment.data)
        return data
    }

    @discardableResult
    func appendMediaSegment(
        _ data: Data,
        duration: Double,
        discontinuity: Bool = false
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let sequence = nextSequence
        nextSequence += 1
        segments.append(MediaSegment(
            sequence: sequence,
            duration: max(0.05, duration),
            data: data,
            discontinuity: discontinuity))
        if segments.count > maximumSegments {
            segments.removeFirst(segments.count - maximumSegments)
        }
        return sequence
    }

    /// Exposed internally for deterministic playlist tests.
    func playlist() -> String {
        lock.lock()
        let snapshot = segments
        let hasInitialization = initializationSegment != nil
        let nextSequenceSnapshot = nextSequence
        lock.unlock()

        let firstSequence = snapshot.first?.sequence ?? nextSequenceSnapshot
        let maximumDuration = snapshot.map(\.duration).max() ?? 1
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, Int(ceil(maximumDuration))))",
            "#EXT-X-MEDIA-SEQUENCE:\(firstSequence)",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if hasInitialization {
            lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
        }
        for segment in snapshot {
            if segment.discontinuity {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("segment\(segment.sequence).m4s")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(
        on connection: NWConnection,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                self.respond(to: request, on: connection)
            } else if error == nil {
                self.receiveRequest(on: connection, accumulated: request)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to requestData: Data, on connection: NWConnection) {
        guard let request = String(data: requestData, encoding: .utf8) else {
            send(status: 400, body: Data(), contentType: "text/plain",
                 headOnly: false, range: nil, on: connection)
            return
        }
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else {
            connection.cancel()
            return
        }
        let components = first.split(separator: " ")
        guard components.count >= 2 else {
            send(status: 400, body: Data(), contentType: "text/plain",
                 headOnly: false, range: nil, on: connection)
            return
        }
        let method = String(components[0])
        let path = String(components[1])
        guard method == "GET" || method == "HEAD" else {
            send(status: 405, body: Data(), contentType: "text/plain",
                 headOnly: false, range: nil, on: connection)
            return
        }

        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else {
            send(status: 404, body: Data(), contentType: "text/plain",
                 headOnly: method == "HEAD", range: nil, on: connection)
            return
        }
        let resource = String(path.dropFirst(prefix.count))
        let response: (Data, String)?
        switch resource {
        case "stream.m3u8":
            response = (Data(playlist().utf8),
                        "application/vnd.apple.mpegurl")
        case "init.mp4":
            lock.lock()
            let data = initializationSegment
            lock.unlock()
            response = data.map { ($0, "video/mp4") }
        default:
            if resource.hasPrefix("segment"),
               resource.hasSuffix(".m4s"),
               let sequence = Int(resource
                    .dropFirst("segment".count)
                    .dropLast(".m4s".count)) {
                lock.lock()
                let data = segments.first {
                    $0.sequence == sequence
                }?.data
                lock.unlock()
                response = data.map { ($0, "video/iso.segment") }
            } else {
                response = nil
            }
        }

        guard let response else {
            send(status: 404, body: Data(), contentType: "text/plain",
                 headOnly: method == "HEAD", range: nil, on: connection)
            return
        }
        let rangeHeader = lines.first {
            $0.lowercased().hasPrefix("range:")
        }
        let range = rangeHeader.flatMap {
            Self.byteRange(from: $0, length: response.0.count)
        }
        send(
            status: range == nil ? 200 : 206,
            body: response.0,
            contentType: response.1,
            headOnly: method == "HEAD",
            range: range,
            on: connection)
    }

    static func byteRange(
        from header: String,
        length: Int
    ) -> ClosedRange<Int>? {
        guard length > 0,
              let value = header.split(
                separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces),
              value.lowercased().hasPrefix("bytes=")
        else { return nil }
        let pair = value.dropFirst("bytes=".count).split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2,
              let start = Int(pair[0]),
              start >= 0, start < length else { return nil }
        let requestedEnd = Int(pair[1]) ?? (length - 1)
        return start...min(length - 1, max(start, requestedEnd))
    }

    private func send(
        status: Int,
        body: Data,
        contentType: String,
        headOnly: Bool,
        range: ClosedRange<Int>?,
        on connection: NWConnection
    ) {
        let payload: Data
        let contentRange: String?
        if let range {
            payload = body.subdata(in: range.lowerBound..<(range.upperBound + 1))
            contentRange =
                "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(body.count)\r\n"
        } else {
            payload = body
            contentRange = nil
        }
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        var header =
            "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(payload.count)\r\n" +
            "Accept-Ranges: bytes\r\n" +
            "Cache-Control: no-cache, no-store\r\n" +
            "Connection: close\r\n"
        if let contentRange { header += contentRange }
        header += "\r\n"
        var response = Data(header.utf8)
        if !headOnly { response.append(payload) }
        connection.send(
            content: response,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
