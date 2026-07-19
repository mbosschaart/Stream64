import Foundation
import Combine
import Network

/// Manages the live connection to one Ultimate device: REST control,
/// video/audio stream lifecycle, and connection state.
@MainActor
final class DeviceSession: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(info: String)
        case error(String)
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var fps: Double = 0
    @Published private(set) var isPaused = false
    @Published var transferStatus: TransferStatus?

    enum TransferStatus: Equatable {
        case uploading(String)
        case done(String)
        case failed(String)
    }

    let device: UltimateDevice
    let videoReceiver = VideoReceiver()
    let audioReceiver = AudioReceiver()
    /// How this stream looks — per-device, persisted by device ID.
    let display: DisplaySettings
    private let settings: AppSettings
    private var client: UltimateAPIClient
    private var displayObserver: AnyCancellable?

    init(device: UltimateDevice, settings: AppSettings) {
        self.display = DisplaySettings.shared(for: device.id)
        self.device = device
        self.settings = settings
        self.client = UltimateAPIClient(device: device, timeout: settings.connectTimeoutSeconds)

        // Keep the RF audio filter in sync with this device's display
        // settings from any control surface (toolbar, context menu, prefs).
        displayObserver = display.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.audioReceiver.rfAudioEnabled =
                    self.display.tubeInput == .rf && self.isCRTFilterActive
            }

        videoReceiver.onStats = { [weak self] fps in
            Task { @MainActor in
                guard let self else { return }
                // Publish only meaningful changes. A steady stream reports
                // 49.8/50.1/49.9... every second; publishing each tick
                // re-renders every observer once a second — which, among
                // other things, rebuilds (and collapses) an open context
                // menu attached to those views.
                if abs(fps - self.fps) >= 0.5 {
                    self.fps = fps
                }
            }
        }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Connection lifecycle

    func connect() async {
        guard !device.host.isEmpty else {
            state = .error("Device has no address configured.")
            return
        }
        state = .connecting
        do {
            // Verify the device is reachable and get its identity.
            let info = try await client.fetchInfo()
            let description = [info.product, info.firmwareVersion]
                .compactMap { $0 }
                .joined(separator: " · ")

            // Start local UDP receivers first so no packets are dropped.
            try videoReceiver.start(port: UInt16(device.videoPort))
            if settings.audioEnabled {
                audioReceiver.volume = Float(settings.volume)
                audioReceiver.bufferSeconds = settings.audioBufferMs / 1000
                audioReceiver.rfAudioEnabled = display.tubeInput == .rf && isCRTFilterActive
                try audioReceiver.start(port: UInt16(device.audioPort))
            }

            do {
                try await startStreaming()
            } catch where error.localizedDescription.contains("Network Host Resolve Error") {
                // Transient wedge: the stack often accepts the same request
                // moments later. Retry once before involving the user.
                try await Task.sleep(for: .seconds(1))
                try await startStreaming()
            }

            state = .connected(info: description.isEmpty ? device.displayAddress : description)
        } catch {
            videoReceiver.stop()
            audioReceiver.stop()
            // Firmware 3.14's streaming stack can wedge and refuse every
            // destination (even plain IPs) with this error until the
            // device reboots; its web server stays up so it looks healthy.
            if error.localizedDescription.contains("Network Host Resolve Error") {
                state = .error("The Ultimate's network stack appears stuck "
                    + "(it rejects all stream destinations). Rebooting the device "
                    + "usually fixes this — use Reboot, then Retry.")
            } else {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Ask the Ultimate to send its video/audio streams to this Mac's
    /// address. Streams stop on the device side after a reboot or when a
    /// configured stream duration expires — call this to (re)start them
    /// without tearing down the local receivers.
    func startStreaming() async throws {
        guard let localIP = LocalNetwork.primaryIPv4Address() else {
            throw UltimateAPIClient.APIError.invalidURL
        }
        try await client.startVideoStream(
            destinationHost: localIP,
            port: device.videoPort,
            durationSeconds: settings.streamDurationSeconds)
        if settings.audioEnabled {
            try await client.startAudioStream(
                destinationHost: localIP,
                port: device.audioPort,
                durationSeconds: settings.streamDurationSeconds)
        }
    }

    /// startStreaming for UI call sites: failures surface in `state`.
    func restartStreams() async {
        await run { try await self.startStreaming() }
    }

    func disconnect() async {
        keyWorker?.cancel()
        keyWorker = nil
        keyQueue.removeAll()
        try? await client.stopVideoStream()
        try? await client.stopAudioStream()
        videoReceiver.stop()
        audioReceiver.stop()
        fps = 0
        isPaused = false
        state = .disconnected
    }

    // MARK: - Machine control

    func reset() async {
        await flushPendingKeys()
        await run { try await self.client.reset() }
    }
    func reboot() async {
        await flushPendingKeys()
        await run { try await self.client.reboot() }
        // Rebooting stops the device-side streams; restart them once the
        // Ultimate is back up (poll until it responds, then re-arm).
        guard isConnected else { return }
        for _ in 0..<15 {
            try? await Task.sleep(for: .seconds(1))
            if (try? await client.fetchInfo()) != nil {
                await run { try await self.startStreaming() }
                return
            }
        }
        state = .error("Device did not come back after reboot.")
    }
    /// Recovery path for a wedged device: reboot it (works even when the
    /// session never connected — it only needs the REST API), wait for it
    /// to come back, then run the normal connect flow.
    func rebootAndReconnect() async {
        state = .connecting
        do {
            try await client.reboot()
        } catch {
            state = .error("Reboot failed: \(error.localizedDescription)")
            return
        }
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if (try? await client.fetchInfo()) != nil {
                await connect()
                return
            }
        }
        state = .error("Device did not come back after reboot.")
    }

    func powerOff() async {
        await run { try await self.client.powerOff() }
        await disconnect()
    }
    func menuButton() async { await run { try await self.client.menuButton() } }

    func togglePause() async {
        if isPaused {
            await run { try await self.client.resume() }
            isPaused = false
        } else {
            await run { try await self.client.pause() }
            isPaused = true
        }
    }

    // MARK: - Keyboard queue
    //
    // Keystrokes are funneled through one queue drained by a single worker:
    // concurrent typeKeys calls would race on the C64's keyboard buffer
    // ($0277/$C6) and drop or reorder keys. Failures are transient (retried
    // once, then reported via the banner) — they never demote `state`, so a
    // hiccup on one keystroke can't disconnect the session.

    private var keyQueue: [UInt8] = []
    private var keyWorker: Task<Void, Never>?

    func sendKeys(_ text: String) {
        enqueueKeys(PETSCII.encode(text))
    }

    func sendKeyCodes(_ codes: [UInt8]) {
        enqueueKeys(codes)
    }

    private func enqueueKeys(_ codes: [UInt8]) {
        guard !codes.isEmpty else { return }
        keyQueue.append(contentsOf: codes)
        startKeyWorkerIfNeeded()
    }

    private func startKeyWorkerIfNeeded() {
        guard keyWorker == nil, !keyQueue.isEmpty else { return }
        keyWorker = Task { [weak self] in
            await self?.drainKeyQueue()
            guard let self else { return }
            self.keyWorker = nil
            // Keys enqueued while the drain was finishing would otherwise
            // strand until the next keystroke.
            self.startKeyWorkerIfNeeded()
        }
    }

    private func drainKeyQueue() async {
        while !keyQueue.isEmpty {
            let batch = keyQueue
            keyQueue.removeAll()
            do {
                try await client.typeKeys(batch)
            } catch {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    try await client.typeKeys(batch)
                } catch {
                    dropKeys(message: "Keyboard: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private func dropKeys(message: String) {
        keyQueue.removeAll()
        transferStatus = .failed(message)
        Task {
            try? await Task.sleep(for: .seconds(4))
            if case .failed = transferStatus { transferStatus = nil }
        }
    }

    /// Abandon queued keystrokes and clear unconsumed keys on the C64 —
    /// used at machine-state boundaries (reset, PRG load) so stale input
    /// can't replay into whatever runs next.
    private func flushPendingKeys() async {
        keyWorker?.cancel()
        keyWorker = nil
        keyQueue.removeAll()
        try? await client.flushKeyboardBuffer()
    }

    /// Load a dropped file: .prg is uploaded and run, disk images are
    /// uploaded and mounted in drive A.
    func loadFile(at url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            await loadData(data, filename: url.lastPathComponent)
        } catch {
            transferStatus = .failed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// How to treat a disk image after upload.
    enum MountBehavior {
        case mountOnly
        /// Mount, then reset and auto-type LOAD"*",8,1 + RUN.
        case mountAndRun
    }

    /// Load in-memory file data (local file or Assembly64 download) onto
    /// the machine, dispatching on the file extension.
    func loadData(_ data: Data, filename: String,
                  mountBehavior: MountBehavior = .mountOnly) async {
        let ext = (filename as NSString).pathExtension.lowercased()
        transferStatus = .uploading(filename)
        do {
            switch ext {
            case "prg":
                await flushPendingKeys()
                try await client.runPRG(data: data)
                transferStatus = .done("Running \(filename)")
            case "d64", "g64", "d71", "g71", "d81":
                try await client.mountDisk(data: data, filename: filename, type: ext)
                if mountBehavior == .mountAndRun {
                    await flushPendingKeys()
                    try await client.reset()
                    // Give BASIC time to come up before typing.
                    try await Task.sleep(for: .seconds(3))
                    try await client.typeKeys(PETSCII.encode("load\"*\",8,1\r"))
                    try await Task.sleep(for: .seconds(1))
                    try await client.typeKeys(PETSCII.encode("run\r"))
                    transferStatus = .done("Booting \(filename)")
                } else {
                    transferStatus = .done("Mounted \(filename) in drive A")
                }
            case "sid":
                try await client.playSID(data: data)
                transferStatus = .done("Playing \(filename)")
            case "crt":
                try await client.runCRT(data: data)
                transferStatus = .done("Running \(filename)")
            default:
                transferStatus = .failed("Unsupported file type: .\(ext)")
                return
            }
        } catch {
            transferStatus = .failed("\(filename): \(error.localizedDescription)")
            return
        }
        // Clear the confirmation after a few seconds.
        let shown = transferStatus
        Task {
            try? await Task.sleep(for: .seconds(4))
            if transferStatus == shown { transferStatus = nil }
        }
    }

    func applyAudioSettings() {
        audioReceiver.volume = Float(settings.volume)
        audioReceiver.bufferSeconds = settings.audioBufferMs / 1000
        audioReceiver.rfAudioEnabled = display.tubeInput == .rf && isCRTFilterActive
    }

    /// The input-signal simulation (including RF audio) only runs when a
    /// CRT filter renders the picture.
    private var isCRTFilterActive: Bool {
        display.filterMode == .crt || display.filterMode == .crtTube
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

/// Helper to determine this Mac's primary IPv4 address (for stream destination).
enum LocalNetwork {
    static func primaryIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var best: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            // Prefer en0 (Wi-Fi / primary Ethernet), fall back to any en*.
            guard name.hasPrefix("en") else { continue }

            var addr = interface.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if name == "en0" { return ip }
                if best == nil { best = ip }
            }
        }
        return best
    }
}
