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

    /// Avoid rewriting the active debug source when it is already selected.
    /// Some firmware applies this configuration mutation live, so a redundant
    /// write during SID playback is needlessly disruptive.
    func ensureDebugStreamMode(_ mode: DebugStreamMode) async throws {
        let settings = try await fetchConfigCategory("Data Streams")
        if settings["Debug Stream Mode"] as? String != mode.rawValue {
            try await setConfigItem(
                category: "Data Streams",
                item: "Debug Stream Mode",
                value: mode.rawValue)
        }
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
        enum SecondSIDSource: Equatable {
            case physicalSocket
            case ultiSID
        }

        struct Slot: Equatable, Identifiable {
            enum Source: String, CaseIterable {
                case socket1
                case socket2
                case ultiSID1
                case ultiSID2

                var configItem: String {
                    switch self {
                    case .socket1: return "SID Socket 1 Address"
                    case .socket2: return "SID Socket 2 Address"
                    case .ultiSID1: return "UltiSID 1 Address"
                    case .ultiSID2: return "UltiSID 2 Address"
                    }
                }

                var label: String {
                    switch self {
                    case .socket1: return "SID socket 1"
                    case .socket2: return "SID socket 2"
                    case .ultiSID1: return "UltiSID 1"
                    case .ultiSID2: return "UltiSID 2"
                    }
                }
            }

            let source: Source
            let address: UInt16
            let model: String?

            var id: Source { source }
            var isPhysical: Bool {
                source == .socket1 || source == .socket2
            }

            var modelConfigItem: String? {
                switch source {
                case .ultiSID1: return "UltiSID 1 Filter Curve"
                case .ultiSID2: return "UltiSID 2 Filter Curve"
                case .socket1, .socket2: return nil
                }
            }
        }

        let socket1Address: UInt16
        let socket1Model: String?
        /// nil when a second SID isn't enabled/detected.
        let socket2Address: UInt16?
        let socket2Model: String?
        /// Which address entry owns `socket2Address`; used by the explicit
        /// compatibility Fix action without guessing physical hardware.
        let secondSIDSource: SecondSIDSource?
        /// Every addressable SID source currently available to the Ultimate.
        /// This lets playback route a 3-SID tune without discarding UltiSIDs
        /// just because physical sockets are present.
        let slots: [Slot]
    }

    struct SIDRoutingResult: Equatable {
        let configuredSlots: [SIDConfiguration.Slot.Source]
        let warnings: [String]

        var description: String {
            var parts: [String] = []
            if !configuredSlots.isEmpty {
                parts.append(
                    "Configured " + configuredSlots.map(\.rawValue).joined(separator: ", ") + ".")
            }
            parts.append(contentsOf: warnings)
            return parts.isEmpty ? "SID routing already matched." : parts.joined(separator: " ")
        }
    }

    enum SIDRoutingError: LocalizedError {
        case playSIDSpecific
        case noCompatibleSlot(address: UInt16, model: String?)

        var errorDescription: String? {
            switch self {
            case .playSIDSpecific:
                return "This PSID uses PlaySID-specific behavior and is unsafe for native C64 playback."
            case .noCompatibleSlot(let address, let model):
                let requirement = model.map { " (\($0))" } ?? ""
                return "No compatible SID is available at \(String(format: "$%04X", address))\(requirement)."
            }
        }
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
        let fallback = SIDConfiguration(
            socket1Address: 0xD400,
            socket1Model: nil,
            socket2Address: nil,
            socket2Model: nil,
            secondSIDSource: nil,
            slots: [])
        guard let addressing = try? await fetchConfigCategory("SID Addressing"),
              let sockets = try? await fetchConfigCategory("SID Sockets Configuration"),
              let ultiSID = try? await fetchConfigCategory("UltiSID Configuration") else {
            return fallback
        }
        let physicalSocket1Enabled = (sockets["SID Socket 1"] as? String) == "Enabled"
        let physicalSocket1Model = Self.detectedSIDModel(
            sockets["SID Detected Socket 1"] as? String)
        let socket2Enabled = (sockets["SID Socket 2"] as? String) == "Enabled"
        let physicalSocket2Model = Self.detectedSIDModel(
            sockets["SID Detected Socket 2"] as? String)

        var slots: [SIDConfiguration.Slot] = []
        if physicalSocket1Enabled, let physicalSocket1Model {
            slots.append(.init(
                source: .socket1,
                address: Self.parseHexAddress(
                    addressing["SID Socket 1 Address"] as? String) ?? 0xD400,
                model: physicalSocket1Model))
        }
        if socket2Enabled, let physicalSocket2Model,
           let address = Self.parseHexAddress(
            addressing["SID Socket 2 Address"] as? String) {
            slots.append(.init(source: .socket2, address: address, model: physicalSocket2Model))
        }
        let ultiSID1 = Self.parseHexAddress(
            addressing["UltiSID 1 Address"] as? String) ?? 0xD400
        let ultiSID2 = Self.parseHexAddress(
            addressing["UltiSID 2 Address"] as? String)
        slots.append(.init(
            source: .ultiSID1,
            address: ultiSID1,
            model: Self.ultiSIDModel(
                ultiSID["UltiSID 1 Filter Curve"] as? String)))
        if let ultiSID2 {
            slots.append(.init(
                source: .ultiSID2,
                address: ultiSID2,
                model: Self.ultiSIDModel(
                    ultiSID["UltiSID 2 Filter Curve"] as? String)))
        }

        // On U64 hardware, active physical sockets are still the preferred
        // oscilloscope source, while auto-routing also keeps UltiSIDs visible.
        if physicalSocket1Enabled, physicalSocket1Model != nil {
            let socket1 = Self.parseHexAddress(
                addressing["SID Socket 1 Address"] as? String) ?? 0xD400
            let socket2 = (socket2Enabled && physicalSocket2Model != nil)
                ? Self.parseHexAddress(
                    addressing["SID Socket 2 Address"] as? String)
                : nil
            return SIDConfiguration(
                socket1Address: socket1,
                socket1Model: physicalSocket1Model,
                socket2Address: socket2,
                socket2Model: socket2 == nil ? nil : physicalSocket2Model,
                secondSIDSource: socket2 == nil ? nil : .physicalSocket,
                slots: slots)
        }

        return SIDConfiguration(
            socket1Address: ultiSID1,
            socket1Model: Self.ultiSIDModel(
                ultiSID["UltiSID 1 Filter Curve"] as? String),
            socket2Address: ultiSID2,
            socket2Model: ultiSID2 == nil ? nil : Self.ultiSIDModel(
                ultiSID["UltiSID 2 Filter Curve"] as? String),
            secondSIDSource: ultiSID2 == nil ? nil : .ultiSID,
            slots: slots)
    }

    /// Applies the addresses declared by a PSID/RSID header immediately before
    /// native playback. Address changes are deliberately persisted: the user
    /// asked the Ultimate to retain the routing that made the tune playable.
    func ensureSIDRouting(for header: SIDHeader) async throws -> SIDRoutingResult {
        guard !header.isPlaySIDSpecific else {
            throw SIDRoutingError.playSIDSpecific
        }
        let configuration = await fetchSIDConfiguration()
        let requirements = zip(
            header.requiredSIDAddresses,
            [header.primarySIDModel, header.secondSIDModel, header.thirdSIDModel])
        var available = configuration.slots
        var addressChanges: [SIDConfiguration.Slot.Source] = []
        var modelChanges: [SIDConfiguration.Slot.Source] = []
        var warnings: [String] = []
        let hasPhysicalSID = configuration.slots.contains(where: \.isPhysical)
        let physicalSIDCount = configuration.slots.filter(\.isPhysical).count

        for (index, requirement) in requirements.enumerated() {
            let (address, requiredModel) = requirement
            let candidates = hasPhysicalSID && index < physicalSIDCount
                ? available.indices.filter { available[$0].isPhysical }
                : Array(available.indices)
            guard !candidates.isEmpty else {
                throw SIDRoutingError.noCompatibleSlot(
                    address: address, model: requiredModel)
            }
            let selectedIndex = candidates.min { lhs, rhs in
                let left = available[lhs]
                let right = available[rhs]
                let leftScore = Self.routingScore(
                    left, address: address, ordinal: index)
                let rightScore = Self.routingScore(
                    right, address: address, ordinal: index)
                return leftScore < rightScore
            }!
            let selected = available.remove(at: selectedIndex)
            if let requiredModel, selected.model != requiredModel {
                if hasPhysicalSID {
                    warnings.append(
                        "\(selected.source.label) is \(selected.model ?? "unknown"); tune requests \(requiredModel).")
                } else if let item = selected.modelConfigItem {
                    try await setConfigItem(
                        category: "UltiSID Configuration",
                        item: item,
                        value: Self.ultiSIDFilterCurve(for: requiredModel))
                    modelChanges.append(selected.source)
                }
            }
            if selected.address != address {
                try await setConfigItem(
                    category: "SID Addressing",
                    item: selected.source.configItem,
                    value: String(format: "$%04X", address))
                addressChanges.append(selected.source)
            }
        }
        if !addressChanges.isEmpty {
            try await saveConfigCategoryToFlash("SID Addressing")
        }
        if !modelChanges.isEmpty {
            try await saveConfigCategoryToFlash("UltiSID Configuration")
        }
        return SIDRoutingResult(
            configuredSlots: Array(Set(addressChanges + modelChanges)),
            warnings: warnings)
    }

    private static func routingScore(
        _ slot: SIDConfiguration.Slot,
        address: UInt16,
        ordinal: Int
    ) -> Int {
        let addressPenalty = slot.address == address ? 0 : 100
        let preferredSource: SIDConfiguration.Slot.Source = switch ordinal {
        case 0: .socket1
        case 1: .socket2
        default: .ultiSID1
        }
        let sourcePenalty = slot.source == preferredSource ? 0 : 10
        return addressPenalty + sourcePenalty
    }

    private static func ultiSIDFilterCurve(for model: String) -> String {
        model == "6581" ? "6581 R2" : "8580 Lo"
    }

    /// Applies the address needed by a PSIDv3/4 second SID. This never
    /// enables/disables sockets or changes the installed SID's model; callers
    /// must only expose it after explicit user confirmation.
    func setSecondSIDAddress(_ address: UInt16) async throws {
        let configuration = await fetchSIDConfiguration()
        guard let source = configuration.secondSIDSource,
              configuration.socket2Address != nil else {
            throw APIError.httpError(
                400,
                "No configured second SID is available.")
        }
        guard configuration.socket2Address != address else { return }
        try await setConfigItem(
            category: "SID Addressing",
            item: source == .physicalSocket
                ? "SID Socket 2 Address"
                : "UltiSID 2 Address",
            value: String(format: "$%04X", address))
        // Persist the specific dirty store rather than relying on a global
        // save sweep. Founder firmware keeps UltiSID addressing in this
        // category even though its physical sockets are disabled.
        try await saveConfigCategoryToFlash("SID Addressing")
    }

    private static func parseHexAddress(_ string: String?) -> UInt16? {
        guard var hex = string else { return nil }
        if hex.hasPrefix("$") { hex.removeFirst() }
        return UInt16(hex, radix: 16)
    }

    private static func detectedSIDModel(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.uppercased()
        if normalized.contains("6581") { return "6581" }
        if normalized.contains("8580") { return "8580" }
        return nil
    }

    private static func ultiSIDModel(_ filterCurve: String?) -> String? {
        detectedSIDModel(filterCurve)
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

    /// Upload a SID tune and play it. The Ultimate API expects multipart data
    /// named `sid`; a raw octet-stream body may lose SID metadata on newer
    /// firmware and breaks multi-SID playback.
    func playSID(
        data: Data,
        filename: String = "tune.sid",
        songNumber: Int? = nil,
        songLengths: Data? = nil
    ) async throws {
        guard Self.isSafeMultipartFilename(filename) else {
            throw APIError.invalidURL
        }
        var items: [URLQueryItem] = []
        if let songNumber {
            items.append(URLQueryItem(name: "songnr", value: String(songNumber)))
        }
        var request = try makeRequest(
            path: "/v1/runners:sidplay",
            method: "POST",
            queryItems: items)
        let boundary = "Stream64-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartSIDBody(
            boundary: boundary,
            sid: data,
            filename: filename,
            songLengths: songLengths)
        try await perform(request)
    }

    static func multipartSIDBody(
        boundary: String,
        sid: Data,
        filename: String,
        songLengths: Data? = nil
    ) -> Data {
        var body = Data()
        func append(_ value: String) {
            body.append(contentsOf: value.utf8)
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"sid\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(sid)
        append("\r\n")
        if let songLengths {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"songlengths\"; filename=\"\(filename).ssl\"\r\n")
            append("Content-Type: application/octet-stream\r\n\r\n")
            body.append(songLengths)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
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

    /// Remove the mounted image from a drive (`PUT …:remove`).
    func unmountDisk(drive: String = "a") async throws {
        try await put("/v1/drives/\(drive):remove")
    }

    func turnDriveOn(drive: String = "a") async throws {
        try await put("/v1/drives/\(drive):on")
    }

    func turnDriveOff(drive: String = "a") async throws {
        try await put("/v1/drives/\(drive):off")
    }

    /// Emulation type: `1541`, `1571`, or `1581`.
    func setDriveMode(drive: String = "a", mode: String) async throws {
        try await put(
            "/v1/drives/\(drive):set_mode",
            queryItems: [URLQueryItem(name: "mode", value: mode)])
    }

    enum BlankDiskKind: String, CaseIterable, Identifiable {
        case d64, d71, d81
        var id: String { rawValue }
        var apiSuffix: String {
            switch self {
            case .d64: return "create_d64"
            case .d71: return "create_d71"
            case .d81: return "create_d81"
            }
        }
        var fileExtension: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    /// Create a blank disk image on the Ultimate filesystem.
    /// `path` is absolute from the device root (e.g. `/Temp/blank.d64`).
    func createBlankDisk(
        path: String,
        kind: BlankDiskKind,
        tracks: Int? = nil,
        diskName: String? = nil
    ) async throws {
        var items: [URLQueryItem] = []
        if let tracks { items.append(URLQueryItem(name: "tracks", value: String(tracks))) }
        if let diskName, !diskName.isEmpty {
            items.append(URLQueryItem(name: "diskname", value: diskName))
        }
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        try await put(
            "/v1/files\(normalized):\(kind.apiSuffix)",
            queryItems: items)
    }

    struct DriveInfo: Equatable, Identifiable {
        var id: String { letter }
        let letter: String
        let enabled: Bool
        let busID: Int?
        let type: String?
        let imageFile: String?
        let partition: String?
    }

    /// Snapshot of IEC / emulated drives (`GET /v1/drives`).
    func fetchDrives() async throws -> [DriveInfo] {
        let request = try makeRequest(path: "/v1/drives", method: "GET")
        let data = try await perform(request)
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let drives = object["drives"] as? [[String: Any]] else {
            throw APIError.httpError(200, "drives response was malformed")
        }
        var result: [DriveInfo] = []
        for entry in drives {
            guard let (letter, payload) = entry.first(
                where: { $0.key.count == 1 && ($0.value as? [String: Any]) != nil }
            ),
                  let info = payload as? [String: Any] else { continue }
            result.append(DriveInfo(
                letter: letter.lowercased(),
                enabled: info["enabled"] as? Bool ?? false,
                busID: info["bus_id"] as? Int,
                type: info["type"] as? String,
                imageFile: (info["image_file"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 },
                partition: (info["partition"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }))
        }
        return result.sorted { $0.letter < $1.letter }
    }

    /// Top-level Ultimate flash config categories (`GET /v1/configs`).
    func fetchConfigCategories() async throws -> [String] {
        let request = try makeRequest(path: "/v1/configs", method: "GET")
        let data = try await perform(request)
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let categories = object["categories"] as? [String] else {
            throw APIError.httpError(200, "configs list was malformed")
        }
        return categories
    }

    /// Key/value items inside one config category.
    func fetchConfigItems(category: String) async throws -> [(key: String, value: String)] {
        let inner = try await fetchConfigCategory(category)
        return inner.keys.sorted().compactMap { key in
            guard let value = inner[key] else { return nil }
            if let string = value as? String {
                return (key, string)
            }
            if let number = value as? NSNumber {
                return (key, number.stringValue)
            }
            return (key, String(describing: value))
        }
    }

    func saveConfigToFlash() async throws {
        try await put("/v1/configs:save_to_flash")
    }

    func saveConfigCategoryToFlash(_ category: String) async throws {
        try await put("/v1/configs/\(category):save_to_flash")
    }

    func loadConfigFromFlash() async throws {
        try await put("/v1/configs:load_from_flash")
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

        /// Product label for UI. Founder units often report bare
        /// `"C64 Ultimate"` while the hostname carries `FOUNDER`.
        var displayProduct: String? {
            let host = hostname?.uppercased() ?? ""
            if host.contains("FOUNDER") {
                return "C64 Ultimate Founder"
            }
            return product
        }

        /// Firmware label for UI. Commodore's C64 Ultimate line briefly
        /// shipped `/v1/info` as `firmware_version: "3.14"` and later
        /// retroactively named that release **1.0.0** — leaving the raw
        /// string makes a Founder look like Ultimate 64 firmware 3.14.
        var displayFirmwareVersion: String? {
            Self.normalizedFirmwareVersion(
                product: product, firmwareVersion: firmwareVersion)
        }

        /// `Product · firmware` used in the viewer subtitle / discovery.
        var connectionDescription: String {
            [displayProduct, displayFirmwareVersion]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: " · ")
        }

        static func normalizedFirmwareVersion(
            product: String?, firmwareVersion: String?
        ) -> String? {
            guard let firmwareVersion, !firmwareVersion.isEmpty else {
                return firmwareVersion
            }
            let product = product ?? ""
            guard product.localizedCaseInsensitiveContains("C64 Ultimate")
            else {
                return firmwareVersion
            }
            // Changelog: "1.0.0 (AKA v3.14.0)". Accept bare 3.14 and 3.14.x.
            let trimmed = firmwareVersion.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if trimmed == "3.14" || trimmed.hasPrefix("3.14.") {
                return "1.0.0"
            }
            return firmwareVersion
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
