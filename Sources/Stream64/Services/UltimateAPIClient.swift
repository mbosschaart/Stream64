import Foundation

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// Client for the Ultimate 64 / Ultimate-II+ REST API (firmware 3.11+) and
/// the C64 Ultimate API-compatible firmware line (1.1+).
/// Endpoints follow the official `/v1/...` API.
struct UltimateAPIClient {
    let device: UltimateDevice
    let timeout: TimeInterval
    let transport: any HTTPTransport

    init(
        device: UltimateDevice,
        timeout: TimeInterval = 5,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.device = device
        self.timeout = timeout
        self.transport = transport
    }

    enum APIError: LocalizedError {
        case invalidURL
        case httpError(Int, String)
        case deviceErrors([String])

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid device address."
            case .httpError(let code, let body):
                return "Device returned HTTP \(code): \(body)"
            case .deviceErrors(let errors):
                return errors.joined(separator: "; ")
            }
        }
    }

    private struct ErrorEnvelope: Decodable {
        let errors: [String]
    }

    // MARK: - Machine control

    func reset() async throws { try await put("/v1/machine:reset") }
    func reboot() async throws { try await put("/v1/machine:reboot") }
    func pause() async throws { try await put("/v1/machine:pause") }
    func resume() async throws { try await put("/v1/machine:resume") }
    func powerOff() async throws { try await put("/v1/machine:poweroff") }
    func menuButton() async throws { try await put("/v1/machine:menu_button") }

    func fetchMenuScreen() async throws -> UltimateMenuScreen {
        let request = try makeRequest(
            path: "/v1/machine:menu_screen", method: "GET")
        let data = try await perform(request)
        return try UltimateMenuScreen(data: data)
    }

    // MARK: - Firmware configuration / input readiness

    struct InputServiceStatus: Equatable {
        let dmaEnabled: Bool
        let webRemoteEnabled: Bool
        let changed: Bool
    }

    func ensureInputServicesEnabled() async throws -> InputServiceStatus {
        let request = try makeRequest(
            path: "/v1/configs/Network Settings", method: "GET")
        let data = try await perform(request)
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let settings = object["Network Settings"]
                as? [String: Any] else {
            throw APIError.httpError(
                200, "Network Settings response was malformed")
        }
        let dma = (settings["Ultimate DMA Service"] as? String) == "Enabled"
        let web = (settings["Web Remote Control Service"] as? String)
            == "Enabled"
        var changed = false
        if !dma {
            try await setConfigItem(
                category: "Network Settings",
                item: "Ultimate DMA Service",
                value: "Enabled")
            changed = true
        }
        if !web {
            try await setConfigItem(
                category: "Network Settings",
                item: "Web Remote Control Service",
                value: "Enabled")
            changed = true
        }
        if changed {
            try await put("/v1/configs:save_to_flash")
        }
        return InputServiceStatus(
            dmaEnabled: true, webRemoteEnabled: true, changed: changed)
    }

    func setConfigItem(
        category: String, item: String, value: String
    ) async throws {
        try await put(
            "/v1/configs/\(category)/\(item)",
            queryItems: [URLQueryItem(name: "value", value: value)])
    }

    private func fetchConfigCategory(_ category: String) async throws -> [String: Any] {
        let request = try makeRequest(path: "/v1/configs/\(category)", method: "GET")
        let data = try await perform(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = object[category] as? [String: Any] else {
            throw APIError.httpError(200, "\(category) response was malformed")
        }
        return inner
    }

    struct SIDConfiguration: Equatable {
        let socket1Address: UInt16
        /// nil when a second SID isn't enabled/detected.
        let socket2Address: UInt16?
    }

    /// Best-effort discovery of the configured SID base address(es), used
    /// to decide whether the SID Oscilloscope shows 3 or 6 channels and
    /// where each chip's registers live. Confirmed against a real U64-II
    /// (2026-08-01): `SID Addressing` holds `"SID Socket 1/2 Address"` as
    /// `"$D400"`-style strings, `SID Sockets Configuration` holds
    /// `"SID Socket 2"` (`"Enabled"`/`"Disabled"`) and
    /// `"SID Detected Socket 2"` (a chip model string, or absent/"None").
    /// Falls back to the common single-SID default ($D400 only) on any
    /// failure — this is a debugging aid, not something that should ever
    /// block or error out the UI.
    func fetchSIDConfiguration() async -> SIDConfiguration {
        let fallback = SIDConfiguration(socket1Address: 0xD400, socket2Address: nil)
        guard let addressing = try? await fetchConfigCategory("SID Addressing"),
              let sockets = try? await fetchConfigCategory("SID Sockets Configuration") else {
            return fallback
        }
        let socket1 = Self.parseHexAddress(addressing["SID Socket 1 Address"] as? String) ?? 0xD400
        let socket2Enabled = (sockets["SID Socket 2"] as? String) == "Enabled"
        let detected = sockets["SID Detected Socket 2"] as? String
        let socket2Detected = detected.map { !$0.isEmpty && $0 != "None" } ?? false
        let socket2 = (socket2Enabled && socket2Detected)
            ? Self.parseHexAddress(addressing["SID Socket 2 Address"] as? String)
            : nil
        return SIDConfiguration(socket1Address: socket1, socket2Address: socket2)
    }

    private static func parseHexAddress(_ string: String?) -> UInt16? {
        guard var hex = string else { return nil }
        if hex.hasPrefix("$") { hex.removeFirst() }
        return UInt16(hex, radix: 16)
    }

    // MARK: - Matrix keyboard / joystick input

    func sendMachineInput(
        _ events: [C64MachineInputEvent]
    ) async throws {
        guard !events.isEmpty, events.count <= 64 else {
            throw APIError.httpError(
                400, "Matrix input requires 1...64 events")
        }
        var request = try makeRequest(
            path: "/v1/machine:input", method: "POST")
        request.setValue(
            "application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            C64MachineInputEnvelope(events: events))
        _ = try await perform(request)
    }

    func releaseAllInput() async throws {
        try await sendMachineInput([.releaseAll])
    }

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
            var ready = false
            var delay = 50_000_000
            for _ in 0..<20 {
                let pending = try await readMemory(
                    address: 0x00C6, length: 1)
                if pending.first == 0 {
                    ready = true
                    break
                }
                try await Task.sleep(nanoseconds: UInt64(delay))
                delay = min(delay * 2, 500_000_000)
            }
            guard ready else {
                throw APIError.httpError(
                    408, "C64 keyboard buffer remained busy")
            }
            try await writeMemory(address: 0x0091, bytes: [0])
            try await writeMemory(address: 0x0277, bytes: chunk)
            try await writeMemory(address: 0x00C6, bytes: [UInt8(chunk.count)])
            // Do not re-read $C6 to "verify": BASIC often drains the buffer
            // between the write and a follow-up readmem, so a partial count
            // looks like failure even when injection succeeded (Mount & Run).
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

    func runPRG(path: String) async throws {
        try await put("/v1/runners:run_prg", queryItems: [
            URLQueryItem(name: "file", value: path),
        ])
    }

    /// Upload a SID tune and play it.
    func playSID(data: Data) async throws {
        var request = try makeRequest(path: "/v1/runners:sidplay", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        try await perform(request)
    }

    func playSID(path: String, songNumber: Int? = nil) async throws {
        var items = [URLQueryItem(name: "file", value: path)]
        if let songNumber {
            items.append(URLQueryItem(
                name: "songnr", value: String(songNumber)))
        }
        try await put("/v1/runners:sidplay", queryItems: items)
    }

    func playMOD(path: String) async throws {
        try await put("/v1/runners:modplay", queryItems: [
            URLQueryItem(name: "file", value: path),
        ])
    }

    /// Upload a cartridge image and run it.
    func runCRT(data: Data) async throws {
        var request = try makeRequest(path: "/v1/runners:run_crt", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        try await perform(request)
    }

    func runCRT(path: String) async throws {
        try await put("/v1/runners:run_crt", queryItems: [
            URLQueryItem(name: "file", value: path),
        ])
    }

    /// Upload a disk image and mount it. `type` (d64/g64/d71/g71/d81) is
    /// otherwise inferred by the device from the filename.
    func mountDisk(data: Data, filename: String, drive: String = "a", type: String? = nil) async throws {
        guard Self.isSafeMultipartFilename(filename) else {
            throw APIError.invalidURL
        }
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

    static func isSafeMultipartFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty,
              filename == (filename as NSString).lastPathComponent,
              filename.count <= 255,
              !filename.contains(where: {
                  $0 == "\r" || $0 == "\n" || $0 == "\"" || $0 == "\\"
              })
        else { return false }
        return filename.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7F
        }
    }

    func mountDisk(
        path: String,
        drive: String = "a",
        type: String? = nil,
        mode: String? = nil
    ) async throws {
        var items = [URLQueryItem(name: "image", value: path)]
        if let type { items.append(URLQueryItem(name: "type", value: type)) }
        if let mode { items.append(URLQueryItem(name: "mode", value: mode)) }
        try await put("/v1/drives/\(drive):mount", queryItems: items)
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

    /// Start the debug bus-trace stream (6510/VIC/1541 cycle trace) toward
    /// `destinationHost:port`. U64/U64 Elite only. The firmware stops the
    /// video stream when the debug stream starts (and vice versa), since
    /// both share the same 100 Mbps link budget.
    func startDebugStream(destinationHost: String, port: Int, durationSeconds: Int = 0) async throws {
        var items = [URLQueryItem(name: "ip", value: "\(destinationHost):\(port)")]
        if durationSeconds > 0 {
            items.append(URLQueryItem(name: "duration", value: String(durationSeconds)))
        }
        try await put("/v1/streams/debug:start", queryItems: items)
    }

    func stopDebugStream() async throws {
        try await put("/v1/streams/debug:stop")
    }

    // MARK: - Debug register ($D7FF, U64 only)

    private struct DebugRegisterResponse: Decodable {
        let value: String
    }

    /// Read the U64 debug register ($D7FF), which also selects the debug
    /// stream's trace source (6510/VIC/1541). Throws on Ultimate-II+/C64
    /// Ultimate hardware, which does not implement this register — callers
    /// use that failure to gate the debug features in the UI.
    func readDebugRegister() async throws -> UInt8 {
        let request = try makeRequest(path: "/v1/machine:debugreg", method: "GET")
        let data = try await perform(request)
        return try Self.parseDebugRegisterValue(data)
    }

    @discardableResult
    func writeDebugRegister(_ value: UInt8) async throws -> UInt8 {
        let request = try makeRequest(path: "/v1/machine:debugreg", method: "PUT", queryItems: [
            URLQueryItem(name: "value", value: String(format: "%02X", value)),
        ])
        let data = try await perform(request)
        return try Self.parseDebugRegisterValue(data)
    }

    private static func parseDebugRegisterValue(_ data: Data) throws -> UInt8 {
        let response = try JSONDecoder().decode(DebugRegisterResponse.self, from: data)
        var hex = response.value.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex.removeFirst(2)
        }
        if hex.hasPrefix("$") {
            hex.removeFirst()
        }
        guard let value = UInt8(hex, radix: 16) else {
            throw APIError.httpError(
                200, "debugreg returned unparsable value '\(response.value)'")
        }
        return value
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
        let request = try makeRequest(path: "/v1/info", method: "GET")
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
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(http.statusCode, body)
        }
        // Current C64 Ultimate firmware can report command failures inside a
        // successful HTTP response. Treat a non-empty errors array as a real
        // failure so connect/retry logic does not accept a stream:start that
        // the device rejected.
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           !envelope.errors.isEmpty {
            throw APIError.deviceErrors(envelope.errors)
        }
        return data
    }
}
