import Foundation
import Combine
import Network
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// Manages the live connection to one Ultimate device: REST control,
/// video/audio stream lifecycle, and connection state.
@MainActor
final class DeviceSession: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        /// Device did not answer the reachability probe. Auto-connect is
        /// suspended until the user explicitly retries.
        case unreachable
        case connected(info: String)
        case error(String)
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var fps: Double = 0
    @Published private(set) var isPaused = false
    /// True while video packets are actually arriving (measured, not
    /// assumed from API acknowledgements).
    @Published private(set) var isStreaming = false
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
    /// Wired up by whichever VideoView currently owns this session's
    /// renderer (single view or a grid tile). Weakly captures the
    /// renderer, so it naturally goes nil if that view is torn down.
    /// Completion-based (rather than a plain synchronous getter) because
    /// capturing the actual filtered picture requires an extra GPU render
    /// pass on the next draw() — see MetalFrameRenderer.requestFilteredScreenshot.
    var captureFrame: ((@escaping (CGImage?) -> Void) -> Void)?
    /// Renderer hooks for the CRT Tube power-down sequence.
    var beginPowerOffVisualEffect: (() -> Void)?
    var cancelPowerOffVisualEffect: (() -> Void)?

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
                self.lastStatsAt = Date()
                let streaming = fps >= 1
                if streaming != self.isStreaming {
                    self.isStreaming = streaming
                }
            }
        }
        startStreamStalenessMonitor()
        startHealthMonitor()
    }

    private var lastStatsAt = Date.distantPast
    private var stalenessMonitor: Task<Void, Never>?

    /// onStats only fires while frames arrive; when the stream dies the
    /// callbacks just stop. This watchdog turns isStreaming off after
    /// three silent seconds.
    private func startStreamStalenessMonitor() {
        stalenessMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if self.isStreaming, Date().timeIntervalSince(self.lastStatsAt) > 3 {
                    self.isStreaming = false
                    self.fps = 0
                }
            }
        }
    }

    // MARK: - Mid-session disconnect detection & automatic reconnect
    //
    // watchForSilentStream only catches "device streams start but send no
    // packets" — it still assumes the REST API is reachable. This monitor
    // catches the other failure mode: the device (or the network path to
    // it) drops out entirely while `state == .connected`. It runs for the
    // lifetime of the session, polling only while connected, so it costs
    // nothing while disconnected/unreachable.

    private var healthMonitor: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private func startHealthMonitor() {
        healthMonitor = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                guard self.isConnected else { consecutiveFailures = 0; continue }
                let probe = UltimateAPIClient(device: self.device, timeout: 3)
                if (try? await probe.fetchInfo()) != nil {
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    // Two misses (~10s) before acting — a single dropped
                    // probe on a flaky network is not a disconnection.
                    if consecutiveFailures >= 2 {
                        consecutiveFailures = 0
                        self.handleConnectionLost()
                    }
                }
            }
        }
    }

    /// The device stopped answering while we were connected. Tear down the
    /// local receivers (their packets are stale) and either hand off to the
    /// automatic reconnect loop or surface an error for the user to retry.
    private func handleConnectionLost() {
        guard isConnected else { return }
        videoReceiver.stop()
        audioReceiver.stop()
        fps = 0
        isStreaming = false
        if settings.reconnectAutomatically {
            state = .connecting
            startReconnectLoop()
        } else {
            state = .error("Connection to the device was lost.")
        }
    }

    /// Repeatedly calls the normal `connect()` flow with backoff until it
    /// succeeds, the setting is turned off, or a manual disconnect/retry
    /// supersedes it. `connect()`'s own reentrancy guard makes this safe to
    /// race against user-initiated connects.
    private func startReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var delaySeconds = 2.0
            while !Task.isCancelled {
                guard let self else { return }
                if self.isConnected { return }
                // This call is the reconnect task itself; it must not cancel
                // the task that owns the retry/backoff loop.
                await self.connect(cancelReconnectTask: false)
                if self.isConnected { return }
                guard self.settings.reconnectAutomatically else { return }
                try? await Task.sleep(for: .seconds(delaySeconds))
                delaySeconds = min(delaySeconds * 1.5, 30)
            }
        }
    }

    /// Reachability probe: can the device answer its REST API at all?
    /// Two quick attempts (the "2 pings") with a short timeout each.
    /// Returns the device info on success so connect doesn't re-fetch it.
    func probeReachability() async -> UltimateAPIClient.DeviceInfo? {
        let probeClient = UltimateAPIClient(device: device, timeout: 2)
        for attempt in 0..<2 {
            if let info = try? await probeClient.fetchInfo() { return info }
            if attempt == 0 {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return nil
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Connection lifecycle

    private var connecting = false

    func connect(cancelReconnectTask: Bool = true) async {
        // Manual connect/retry supersedes an automatic loop. Automatic loop
        // attempts pass false so they do not self-cancel before their first
        // throwing suspension point.
        if cancelReconnectTask {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        guard !device.host.isEmpty else {
            state = .error("Device has no address configured.")
            return
        }
        // Reentrancy guard: connect is triggered from several places
        // (auto-connect .task, Retry button, watchdog, grid tiles) and two
        // interleaved runs race on the audio engine (CoreAudio error 35)
        // and the receivers.
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }

        state = .connecting
        cancelPowerOffVisualEffect?()
        streamsStoppedByUser = false
        fps = 0
        isStreaming = false

        // Reachability first ("2 pings"): a device that doesn't answer gets
        // the explicit .unreachable state and no further automatic retries —
        // reconnection is up to the user from there. The probe's info reply
        // doubles as the identity fetch.
        guard let info = await probeReachability() else {
            state = .unreachable
            return
        }
        let description = [info.product, info.firmwareVersion]
            .compactMap { $0 }
            .joined(separator: " · ")

        do {
            // Start local UDP receivers first so no packets are dropped.
            try videoReceiver.start(port: UInt16(device.videoPort))
            let audioOK = startAudioIfEnabled()
            // Receivers expose lifetime packet counters. Snapshot after
            // opening them and only treat packets arriving *after this
            // connection attempt* as proof of an already-running stream.
            // Comparing against zero caused reconnects to mistake packets
            // from a previous session for a live stream and skip stream:start.
            let videoPacketBaseline = videoReceiver.packetsReceived
            let audioPacketBaseline = audioReceiver.packetsReceived

            // Pick up already-running streams before commanding new ones:
            // if the device is still sending to us (app restart), don't
            // disturb it. Video and audio are independent device-side
            // streams — check each; one being live must not skip
            // (re)starting the other, or an expired audio stream stays
            // silently dead behind a working picture.
            var videoLive = false
            var audioLive = false
            for _ in 0..<6 { // up to 600 ms
                try await Task.sleep(for: .milliseconds(100))
                videoLive = videoReceiver.packetsReceived > videoPacketBaseline
                audioLive = audioReceiver.packetsReceived > audioPacketBaseline
                if videoLive && (audioLive || !settings.audioEnabled) { break }
            }

            if !videoLive || (settings.audioEnabled && !audioLive) {
                do {
                    try await startStreaming(video: !videoLive,
                                             audio: settings.audioEnabled && !audioLive)
                } catch where error.localizedDescription.contains("Network Host Resolve Error") {
                    // Transient wedge: the stack often accepts the same
                    // request moments later. Retry once.
                    try await Task.sleep(for: .seconds(1))
                    try await startStreaming(video: !videoLive,
                                             audio: settings.audioEnabled && !audioLive)
                }
            }

            state = .connected(info: description.isEmpty ? device.displayAddress : description)
            if !audioOK {
                recoverAudioQuietly()
            }
            watchForSilentStream()
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

    /// Configure and start the audio receiver. Returns false on failure
    /// (audio never blocks the connection).
    private func startAudioIfEnabled() -> Bool {
        guard settings.audioEnabled else { return true }
        audioReceiver.volume = Float(settings.volume)
        audioReceiver.bufferSeconds = settings.audioBufferMs / 1000
        audioReceiver.rfAudioEnabled = display.tubeInput == .rf && isCRTFilterActive
        do {
            try audioReceiver.start(port: UInt16(device.audioPort))
            return true
        } catch {
            return false
        }
    }

    /// CoreAudio start failures are almost always transient (engine
    /// restarted in quick succession). Retry in the background for a few
    /// seconds before bothering the user with a banner.
    private func recoverAudioQuietly() {
        Task { [weak self] in
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isConnected else { return }
                if self.startAudioIfEnabled() { return }
            }
            self?.transferStatus = .failed("Audio unavailable — video only. Reconnect to retry.")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if let self, case .failed = self.transferStatus { self.transferStatus = nil }
            }
        }
    }

    /// User explicitly stopped the streams; the silent-stream watchdog
    /// must not fight them by re-kicking.
    private var streamsStoppedByUser = false

    /// After connect, verify frames actually arrive. The device sometimes
    /// acknowledges stream-start without sending packets (notably right
    /// after a cold power-on); one stop/start re-kick fixes it. Bounded to
    /// a few attempts so a genuinely broken path still surfaces as an error.
    private func watchForSilentStream(attempt: Int = 0) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.isConnected, !self.streamsStoppedByUser else { return }
            if self.fps < 1 {
                if attempt < 2 {
                    try? await self.startStreaming()
                    self.watchForSilentStream(attempt: attempt + 1)
                } else {
                    self.transferStatus = .failed(
                        "No video arriving — check firewall/UDP path, or use Start Streaming.")
                }
            }
        }
    }

    /// Ask the Ultimate to send its video/audio streams to this Mac's
    /// address. Streams stop on the device side after a reboot or when a
    /// configured stream duration expires — call this to (re)start them
    /// without tearing down the local receivers.
    func startStreaming(video: Bool = true, audio: Bool? = nil) async throws {
        guard let localIP = LocalNetwork.primaryIPv4Address(reachingDevice: device.host) else {
            throw UltimateAPIClient.APIError.invalidURL
        }
        let startAudio = audio ?? settings.audioEnabled
        // Always stop, settle, then start: after a cold power-on the device
        // accepts a bare start (HTTP 200) but silently sends no packets —
        // a stop/start cycle reliably kicks the generator into streaming.
        //
        // Do not send start immediately after stop. C64 Ultimate firmware
        // 1.1.0 needs time to tear down the old stream destination; an
        // immediate start can fail with "Network Host Resolve Error" even
        // for a literal IP. Stop all requested streams first, wait once,
        // then start them.
        if video {
            try? await client.stopVideoStream()
        }
        if startAudio {
            try? await client.stopAudioStream()
        }
        if video || startAudio {
            try await Task.sleep(for: .seconds(1))
        }
        if video {
            try await client.startVideoStream(
                destinationHost: localIP,
                port: device.videoPort,
                durationSeconds: settings.streamDurationSeconds)
        }
        if startAudio {
            try await client.startAudioStream(
                destinationHost: localIP,
                port: device.audioPort,
                durationSeconds: settings.streamDurationSeconds)
        }
    }

    /// startStreaming for UI call sites: failures surface in `state`.
    func restartStreams() async {
        streamsStoppedByUser = false
        await run { try await self.startStreaming() }
        watchForSilentStream()
    }

    /// Ask the device to stop sending streams, keeping the session (REST
    /// control, keyboard, file loading) alive. Counterpart of
    /// restartStreams; the picture freezes on the last received frame.
    func stopStreams() async {
        streamsStoppedByUser = true
        try? await client.stopVideoStream()
        try? await client.stopAudioStream()
        fps = 0
        isStreaming = false
    }

    func disconnect(stopRemoteStreams: Bool = true) async {
        reconnectTask?.cancel()
        reconnectTask = nil
        keyWorker?.cancel()
        keyWorker = nil
        keyQueue.removeAll()
        if stopRemoteStreams {
            try? await client.stopVideoStream()
            try? await client.stopAudioStream()
        }
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
        do {
            try await client.powerOff()
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        if display.filterMode == .crtTube {
            beginPowerOffVisualEffect?()
            audioReceiver.playPowerOffCrackle()
            try? await Task.sleep(for: .milliseconds(900))
        }
        // The device is already powered down; avoid two REST timeouts trying
        // to stop streams on a server that no longer exists.
        await disconnect(stopRemoteStreams: false)
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
            _ = await loadData(data, filename: url.lastPathComponent)
        } catch {
            transferStatus = .failed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// How to treat a disk image after upload.
    enum MountBehavior: Codable, Equatable {
        case mountOnly
        /// Mount, then reset and auto-type LOAD"*",8,1 + RUN.
        case mountAndRun
    }

    enum LoadOutcome: Equatable {
        case running(String)
        case mounted(String)
        case booting(String)
        case playing(String)
    }

    /// Load in-memory file data (local file or Assembly64 download) onto
    /// the machine, dispatching on the file extension. Returning an outcome
    /// lets library/history callers persist intent only after the Ultimate
    /// accepted the operation; drag-and-drop callers may ignore it.
    @discardableResult
    func loadData(_ data: Data, filename: String,
                  mountBehavior: MountBehavior = .mountOnly) async -> LoadOutcome? {
        let ext = (filename as NSString).pathExtension.lowercased()
        transferStatus = .uploading(filename)
        let outcome: LoadOutcome
        do {
            switch ext {
            case "prg":
                await flushPendingKeys()
                try await client.runPRG(data: data)
                transferStatus = .done("Running \(filename)")
                outcome = .running(filename)
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
                    outcome = .booting(filename)
                } else {
                    transferStatus = .done("Mounted \(filename) in drive A")
                    outcome = .mounted(filename)
                }
            case "sid":
                try await client.playSID(data: data)
                transferStatus = .done("Playing \(filename)")
                outcome = .playing(filename)
            case "crt":
                try await client.runCRT(data: data)
                transferStatus = .done("Running \(filename)")
                outcome = .running(filename)
            default:
                transferStatus = .failed("Unsupported file type: .\(ext)")
                return nil
            }
        } catch {
            transferStatus = .failed("\(filename): \(error.localizedDescription)")
            return nil
        }
        scheduleClearTransferStatus()
        return outcome
    }

    /// Clear the transfer banner after a few seconds, unless it has already
    /// changed to something newer in the meantime.
    private func scheduleClearTransferStatus(after seconds: Double = 4) {
        let shown = transferStatus
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if transferStatus == shown { transferStatus = nil }
        }
    }

    // MARK: - Screenshot

    /// Captures exactly what's on screen right now — CRT tube curvature,
    /// scanlines, phosphor mask, composite/RF artifacts, and picture
    /// controls all included, since this re-runs the same GPU pipeline
    /// that renders the live view — and prompts the user to save it as a
    /// PNG. The renderer call is asynchronous (one frame of latency): it
    /// hooks into the *next* draw() to encode an extra offscreen pass.
    func saveScreenshot() {
        guard let captureFrame else {
            transferStatus = .failed("No frame available to capture yet.")
            scheduleClearTransferStatus()
            return
        }
        captureFrame { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let image else {
                    self.transferStatus = .failed("No frame available to capture yet.")
                    self.scheduleClearTransferStatus()
                    return
                }
                self.presentScreenshotSavePanel(for: image)
            }
        }
    }

    private func presentScreenshotSavePanel(for image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.screenshotFilename(for: device.name)
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }
            guard let data = Self.pngData(from: image) else {
                self.transferStatus = .failed("Could not encode screenshot.")
                self.scheduleClearTransferStatus()
                return
            }
            do {
                try data.write(to: url)
                self.transferStatus = .done("Saved \(url.lastPathComponent)")
            } catch {
                self.transferStatus = .failed("Save failed: \(error.localizedDescription)")
            }
            self.scheduleClearTransferStatus()
        }
    }

    private static func screenshotFilename(for deviceName: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(deviceName) \(formatter.string(from: Date()))"
    }

    private static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
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
    /// Returns this Mac's best routable IPv4 address to use as the stream
    /// destination for a given device IP. Selection priority:
    /// 1. Any en* interface whose subnet contains the device IP
    /// 2. Any routable (non-link-local) en* address
    /// 3. Any routable non-loopback address
    /// Link-local 169.254.x.x addresses are always excluded — the device
    /// cannot reach them across a LAN.
    static func primaryIPv4Address(reachingDevice deviceIP: String? = nil) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        struct Candidate { let ip: String; let isEn: Bool; let sameSubnet: Bool }
        var candidates: [Candidate] = []

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name != "lo0" else { continue }

            var addr = iface.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(&addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)

            // Skip link-local (169.254.x.x) — unusable across a LAN.
            guard !ip.hasPrefix("169.254.") else { continue }

            // Check same-subnet match using the interface's netmask.
            var onSameSubnet = false
            if let devIP = deviceIP,
               let netmaskPtr = iface.ifa_netmask {
                var nm = netmaskPtr.pointee
                var nmBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&nm, socklen_t(netmaskPtr.pointee.sa_len),
                               &nmBuf, socklen_t(nmBuf.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let mask = String(cString: nmBuf)
                    onSameSubnet = sameSubnet(ip, devIP, mask: mask)
                }
            }
            candidates.append(Candidate(ip: ip, isEn: name.hasPrefix("en"),
                                         sameSubnet: onSameSubnet))
        }

        // Priority: same-subnet en* > same-subnet other > routable en* > routable other
        return candidates.sorted {
            if $0.sameSubnet != $1.sameSubnet { return $0.sameSubnet }
            return $0.isEn && !$1.isEn
        }.first?.ip
    }

    private static func sameSubnet(_ a: String, _ b: String, mask: String) -> Bool {
        func toInt(_ s: String) -> UInt32 {
            let parts = s.split(separator: ".").compactMap { UInt32($0) }
            guard parts.count == 4 else { return 0 }
            return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        }
        let m = toInt(mask)
        return (toInt(a) & m) == (toInt(b) & m)
    }
}
