import Foundation

/// Client for the Ultimate 64 / Ultimate-II+ REST API (firmware 3.11+).
/// Endpoints follow the official `/v1/...` API.
struct UltimateAPIClient {
    let device: UltimateDevice
    let timeout: TimeInterval

    init(device: UltimateDevice, timeout: TimeInterval = 5) {
        self.device = device
        self.timeout = timeout
    }

    enum APIError: LocalizedError {
        case invalidURL
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid device address."
            case .httpError(let code, let body):
                return "Device returned HTTP \(code): \(body)"
            }
        }
    }

    // MARK: - Machine control

    func reset() async throws { try await put("/v1/machine:reset") }
    func reboot() async throws { try await put("/v1/machine:reboot") }
    func pause() async throws { try await put("/v1/machine:pause") }
    func resume() async throws { try await put("/v1/machine:resume") }
    func powerOff() async throws { try await put("/v1/machine:poweroff") }
    func menuButton() async throws { try await put("/v1/machine:menu_button") }

    // MARK: - Keyboard (via DMA memory access)

    /// Read `length` bytes of C64 memory.
    func readMemory(address: UInt16, length: Int) async throws -> Data {
        let request = try makeRequest(path: "/v1/machine:readmem", method: "GET", queryItems: [
            URLQueryItem(name: "address", value: String(format: "%04X", address)),
            URLQueryItem(name: "length", value: String(length)),
        ])
        return try await perform(request)
    }

    func writeMemory(address: UInt16, bytes: [UInt8]) async throws {
        try await put("/v1/machine:writemem", queryItems: [
            URLQueryItem(name: "address", value: String(format: "%04X", address)),
            URLQueryItem(name: "data", value: bytes.map { String(format: "%02X", $0) }.joined()),
        ])
    }

    /// Type PETSCII codes into the KERNAL keyboard buffer ($0277, pending
    /// count at $C6). The REST API has no keyboard endpoint, so keys are
    /// injected with DMA writes, at most 10 at a time (the buffer's size).
    /// Only reaches programs that read keys through the KERNAL (BASIC,
    /// most utilities) — not games that scan the keyboard matrix directly.
    func typeKeys(_ codes: [UInt8]) async throws {
        var index = 0
        while index < codes.count {
            let chunk = Array(codes[index..<min(index + 10, codes.count)])
            // Give the machine a moment to drain what's already pending,
            // then write regardless. $C6 is only meaningful while the KERNAL
            // owns the zero page — a running program may reuse it for its
            // own data, so a stuck nonzero value proves nothing. Overwriting
            // is safe: unconsumed keys are flushed at reset/PRG boundaries.
            for _ in 0..<25 {
                guard let pending = try? await readMemory(address: 0x00C6, length: 1) else { break }
                if pending.first == 0 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try await writeMemory(address: 0x0277, bytes: chunk)
            try await writeMemory(address: 0x00C6, bytes: [UInt8(chunk.count)])
            index += chunk.count
        }
    }

    /// Discard any pending (unconsumed) keys in the KERNAL keyboard buffer.
    func flushKeyboardBuffer() async throws {
        try await writeMemory(address: 0x00C6, bytes: [0])
    }

    // MARK: - File loading

    /// Upload a PRG and run it (reset + DMA load + RUN).
    func runPRG(data: Data) async throws {
        var request = try makeRequest(path: "/v1/runners:run_prg", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        try await perform(request)
    }

    /// Upload a SID tune and play it.
    func playSID(data: Data) async throws {
        var request = try makeRequest(path: "/v1/runners:sidplay", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        try await perform(request)
    }

    /// Upload a cartridge image and run it.
    func runCRT(data: Data) async throws {
        var request = try makeRequest(path: "/v1/runners:run_crt", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        try await perform(request)
    }

    /// Upload a disk image and mount it. `type` (d64/g64/d71/g71/d81) is
    /// otherwise inferred by the device from the filename.
    func mountDisk(data: Data, filename: String, drive: String = "a", type: String? = nil) async throws {
        var items: [URLQueryItem] = []
        if let type {
            items.append(URLQueryItem(name: "type", value: type))
        }
        var request = try makeRequest(path: "/v1/drives/\(drive):mount", method: "POST", queryItems: items)
        let boundary = "Stream64-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        try await perform(request)
    }

    // MARK: - Streams

    /// Start the video (VIC) stream toward `destinationHost:port`.
    func startVideoStream(destinationHost: String, port: Int, durationSeconds: Int = 0) async throws {
        var items = [URLQueryItem(name: "ip", value: "\(destinationHost):\(port)")]
        if durationSeconds > 0 {
            items.append(URLQueryItem(name: "duration", value: String(durationSeconds)))
        }
        try await put("/v1/streams/video:start", queryItems: items)
    }

    func stopVideoStream() async throws {
        try await put("/v1/streams/video:stop")
    }

    /// Start the audio stream toward `destinationHost:port`.
    func startAudioStream(destinationHost: String, port: Int, durationSeconds: Int = 0) async throws {
        var items = [URLQueryItem(name: "ip", value: "\(destinationHost):\(port)")]
        if durationSeconds > 0 {
            items.append(URLQueryItem(name: "duration", value: String(durationSeconds)))
        }
        try await put("/v1/streams/audio:start", queryItems: items)
    }

    func stopAudioStream() async throws {
        try await put("/v1/streams/audio:stop")
    }

    // MARK: - Info

    struct DeviceInfo: Decodable {
        let product: String?
        let firmwareVersion: String?
        let hostname: String?
        let uniqueId: String?

        enum CodingKeys: String, CodingKey {
            case product
            case firmwareVersion = "firmware_version"
            case hostname
            case uniqueId = "unique_id"
        }
    }

    /// Fetch device version/info — also used as a connectivity test.
    func fetchInfo() async throws -> DeviceInfo {
        let request = try makeRequest(path: "/v1/version", method: "GET")
        let data = try await perform(request)
        return try JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    // MARK: - Plumbing

    private func makeRequest(path: String, method: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        guard let base = device.baseURL,
              var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if !device.password.isEmpty {
            request.setValue(device.password, forHTTPHeaderField: "X-Password")
        }
        return request
    }

    private func put(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        let request = try makeRequest(path: path, method: "PUT", queryItems: queryItems)
        try await perform(request)
    }

    @discardableResult
    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(http.statusCode, body)
        }
        return data
    }
}
