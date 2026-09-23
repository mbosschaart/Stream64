import Foundation
import Combine
import Network
import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import UniformTypeIdentifiers

/// Stream / present rates for the FPS overlay. Kept off `DeviceSession`'s
/// `objectWillChange` so 1 Hz ticks cannot rebuild `VideoView` hosts and
/// stall the 50 Hz present pump (visible as a once-per-second scroll hitch).
@MainActor
final class VideoFrameStats: ObservableObject {
    @Published var streamFPS: Double = 0
    @Published var presentFPS: Double = 0
}

/// Manages the live connection to one Ultimate device: REST control,
/// video/audio stream lifecycle, and connection state.
@MainActor
final class DeviceSession: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        /// Device did not answer; automatic retries may be waiting in backoff.
        case unreachable
        case connected(info: String)
        case error(String)
    }

    @Published private(set) var state: ConnectionState = .disconnected
    /// Hardware identity from /v1/info, not the user's editable device name.
    /// Visualization mirrors read this on their existing refresh cadence.
    private(set) var reportedProduct: String?
    /// Assembled UDP frames per second (receive path) — not Metal presents.
    /// Not `@Published`: UI reads `videoFrameStats` instead (see that type).
    private(set) var fps: Double = 0
    /// Completed Metal presents per second for the live viewer (display path).
    private(set) var presentFPS: Double = 0
    /// Observable FPS overlay source — only FPS labels should observe this.
    let videoFrameStats = VideoFrameStats()
    /// Low-rate transport/render observability. Kept off this session's
    /// `objectWillChange` so opening diagnostics cannot disturb the video host.
    let streamDiagnostics = StreamDiagnostics()
    @Published private(set) var isPaused = false
    /// Movie capture state. Source recording observes decoded UDP frames;
    /// filtered recording is supplied by the owning Metal renderer.
    @Published private(set) var isRecording = false
    /// True while video packets are actually arriving (measured, not
    /// assumed from API acknowledgements).
    @Published private(set) var isStreaming = false
    @Published var transferStatus: TransferStatus?
    /// Set from `MetalFrameRenderer` when the CRT display path is under
    /// pressure — GPU in-flight slots exhausted *or* presents slowed by
    /// main-thread contention (SID / memory-map work). Not `@Published` —
    /// Debug Trace / 3D map / SID poll it on their own timers so SwiftUI
    /// trees are not invalidated by load flips.
    private(set) var isVideoGPUBehind = false

    enum TransferStatus: Equatable {
        case uploading(String)
        case done(String)
        case failed(String)
    }

    /// Lifecycle of the debug bus-trace stream (see `startDebugTrace`).
    enum DebugTraceState: Equatable {
        case inactive
        case starting
        case active(DebugStreamMode)
        case error(String)
    }

    @Published private(set) var debugTraceState: DebugTraceState = .inactive
    private var debugTraceConsumers = Set<UUID>()
    /// Optional connection-lifetime lease, controlled by
    /// `keepDebugStreamWarm`. It prevents first-window debug:start churn.
    private var warmDebugTraceLease: UUID?
    /// Last explicitly active debug mode, retained across a reconnect so a
    /// C64U that reset its stream destination re-establishes its debug trace
    /// alongside video and audio.
    private var reconnectDebugTraceMode: DebugStreamMode?
    /// Runs debug capability/prewarm after video/audio are available. SID
    /// playback awaits this task, but normal reconnect UI does not.
    private var debugPrewarmTask: Task<Void, Never>?
    /// Runs input.prepare() in the background after connect. Stored so it can
    /// be cancelled on disconnect; without a handle it accumulates across
    /// reconnects if prepare() takes longer than the connection lifetime.
    private var inputPrepareTask: Task<Void, Never>?
    /// Whether this device's firmware implements the U64 debug register —
    /// Ultimate-II+ and C64 Ultimate hardware do not. Populated by a
    /// silent, best-effort probe once connected; gates the Debug Trace /
    /// Ultimate Menu menu entries.
    @Published private(set) var supportsDebugFeatures = false
    /// Changes every time the user explicitly resets/reboots/powers off
    /// the machine. Visualizations that reconstruct state purely from
    /// register *writes* (SID Oscilloscope, most of all) have no
    /// reliable way to detect "the chip went silent" from the debug
    /// trace alone — a reset may not itself generate any register
    /// writes — so they observe this instead and clear their own
    /// reconstructed state proactively rather than keep showing
    /// whatever was last derived before the reset.
    @Published private(set) var machineResetToken = UUID()
    @Published private(set) var sidPlayback = SIDPlaybackMetadata()

    let device: UltimateDevice
    let videoReceiver = VideoReceiver()
    let audioReceiver = AudioReceiver()
    let debugStreamReceiver = DebugStreamReceiver()
    private let recordingController = RecordingController()
    /// How this stream looks — per-device, persisted by device ID.
    let display: DisplaySettings
    let input: C64InputController
    private let settings: AppSettings
    private let transport: any HTTPTransport
    private var client: UltimateAPIClient
    private let psid64 = PSID64Service()
    /// Shared REST client for tool windows (Drive Bay, Config, Memory Console).
    var api: UltimateAPIClient { client }
    private var displayObserver: AnyCancellable?
    /// Wired up by whichever VideoView currently owns this session's
    /// renderer (single view or a grid tile). Weakly captures the
    /// renderer, so it naturally goes nil if that view is torn down.
    /// Completion-based (rather than a plain synchronous getter) because
    /// capturing the actual filtered picture requires an extra GPU render
    /// pass on the next draw() — see MetalFrameRenderer.requestFilteredScreenshot.
    var captureFrame: ((@escaping (CGImage?) -> Void) -> Void)?
    /// Installed by the active VideoView. A filtered recording must be owned
    /// by a renderer because its active effects/palette live on that renderer.
    var filteredRecordingOutputSize: ((FilteredRecordingSize) -> CGSize?)?
    var startFilteredRecording: (
        (_ size: FilteredRecordingSize,
         _ makePixelBuffer: @escaping () -> CVPixelBuffer?,
         _ consume: @escaping (CVPixelBuffer) -> Void) -> Bool
    )?
    var stopFilteredRecording: (() -> Void)?
    private var activeRecordingMode: RecordingMode?
    /// Renderer hooks for the CRT Tube power-down sequence.
    var beginPowerOffVisualEffect: (() -> Void)?
    var cancelPowerOffVisualEffect: (() -> Void)?
    /// Owned by the currently mounted `VideoView`; weak capture means an old
    /// renderer naturally falls out of diagnostics after its view is removed.
    private var rendererDiagnosticsProvider: (() -> MetalRendererDiagnostics?)?

    init(device: UltimateDevice, settings: AppSettings,
         transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.display = DisplaySettings.shared(for: device.id)
        self.input = C64InputController(device: device)
        self.device = device
        self.settings = settings
        self.transport = transport
        self.client = UltimateAPIClient(device: device, timeout: settings.connectTimeoutSeconds, transport: transport)

        videoReceiver.addFrameObserver { [weak recordingController] frame in
            recordingController?.enqueue(frame: frame)
        }
        audioReceiver.addSampleObserver { [weak recordingController] samples in
            recordingController?.enqueue(audioSamples: samples)
        }

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
                    self.videoFrameStats.streamFPS = fps
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
        startDiagnosticsMonitor()
        refreshNetworkRoute()
    }

    func attachRendererDiagnostics(
        _ provider: @escaping () -> MetalRendererDiagnostics?
    ) {
        rendererDiagnosticsProvider = provider
    }

    /// Called on the main thread from `MetalFrameRenderer` after presents /
    /// semaphore misses. Updates display-path FPS and GPU back-pressure.
    func reportVideoRenderLoad(presentFPS: Double, gpuBehind: Bool) {
        if abs(presentFPS - self.presentFPS) >= 0.5 {
            self.presentFPS = presentFPS
            videoFrameStats.presentFPS = presentFPS
        }
        isVideoGPUBehind = gpuBehind
    }

    private var lastStatsAt = Date.distantPast
    private var stalenessMonitor: Task<Void, Never>?
    private var streamRecoveryTask: Task<Void, Never>?
    private var diagnosticsMonitor: Task<Void, Never>?
    private var previousVideoDiagnostics = VideoReceiverDiagnostics()
    private var previousAudioDiagnostics = AudioReceiverDiagnostics()
    private var previousRendererDiagnostics = MetalRendererDiagnostics()
    private var previousRecordingDiagnostics = RecordingDiagnostics()
    private var lastDiagnosticsSample = Date()
    private var previousDebugBytes = 0
    private var streamHealthLog: StreamHealthLog?
    /// Single generation-scoped silent-stream watchdog. Replaced on each
    /// schedule so connect/recovery/restart cannot stack overlapping
    /// stop/settle/start cycles.
    private var silentStreamWatchTask: Task<Void, Never>?
    /// Restarts debug:start when an "active" bus-trace stops delivering
    /// packets (C64 Ultimate Founder drops debug on VIC re-arm).
    private var silentDebugWatchTask: Task<Void, Never>?

    /// onStats only fires while frames arrive; when the stream dies the
    /// callbacks just stop. This watchdog turns isStreaming off after
    /// three silent seconds.
    private func startStreamStalenessMonitor() {
        stalenessMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if Date().timeIntervalSince(self.lastStatsAt) > 3 {
                    // Age sticky fps so silent-stream watch (fps < 1) can
                    // fire even when onStats simply stopped updating.
                    if self.fps >= 1 {
                        self.fps = 0
                        self.videoFrameStats.streamFPS = 0
                    }
                    if self.isStreaming {
                        self.isStreaming = false
                        self.resetFrameStats()
                        self.isVideoGPUBehind = false
                        self.recoverStaleStreams()
                    }
                }
            }
        }
    }

    /// Samples queue-confined receiver counters and main-thread renderer state
    /// once per second. The resulting observable is intentionally the only
    /// diagnostics publication point.
    private func startDiagnosticsMonitor() {
        diagnosticsMonitor?.cancel()
        diagnosticsMonitor = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.publishDiagnostics()
                tick += 1
                // Follow a Wi-Fi ↔ Ethernet switch without a reconnect.
                if tick % 5 == 0, self.refreshNetworkRoute() {
                    self.applyNetworkBuffering()
                }
            }
        }
    }

    private func publishDiagnostics() {
        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(lastDiagnosticsSample))
        let video = videoReceiver.diagnosticsSnapshot()
        let audio = audioReceiver.diagnosticsSnapshot()
        let renderer = rendererDiagnosticsProvider?() ?? MetalRendererDiagnostics()
        let recording = recordingController.diagnosticsSnapshot()
        func rate(_ current: Int, _ previous: Int) -> Double {
            Double(max(0, current - previous)) / elapsed
        }
        func megabits(_ current: Int, _ previous: Int) -> Double {
            rate(current, previous) * 8 / 1_000_000
        }
        let debugBytes = debugStreamReceiver.bytesReceived
        let debugRate = megabits(debugBytes, previousDebugBytes)
        previousDebugBytes = debugBytes
        let playout = video.playout
        let previousPlayout = previousVideoDiagnostics.playout
        let buffering = StreamDiagnosticsSnapshot.Buffering(
            enabled: playout != nil,
            targetFrames: playout?.targetFrames ?? 0,
            bufferedFrames: playout?.bufferedFrames ?? 0,
            underrunsPerSecond: rate(
                playout?.underruns ?? 0, previousPlayout?.underruns ?? 0),
            concealedFramesPerSecond: rate(
                video.concealedFrames, previousVideoDiagnostics.concealedFrames),
            overflowDropsPerSecond: rate(
                playout?.overflowDrops ?? 0, previousPlayout?.overflowDrops ?? 0))
        let snapshot = StreamDiagnosticsSnapshot(
            video: .init(
                packetsPerSecond: rate(video.packets, previousVideoDiagnostics.packets),
                framesPerSecond: rate(video.completedFrames, previousVideoDiagnostics.completedFrames),
                rejectedPacketsPerSecond: rate(
                    video.rejectedPackets, previousVideoDiagnostics.rejectedPackets),
                frameHeight: video.frameHeight,
                megabitsPerSecond: megabits(video.bytes, previousVideoDiagnostics.bytes),
                lostPacketsPerSecond: rate(
                    video.lostPackets, previousVideoDiagnostics.lostPackets),
                reorderedPacketsPerSecond: rate(
                    video.reorderedPackets, previousVideoDiagnostics.reorderedPackets),
                droppedFramesPerSecond: rate(
                    video.droppedFrames, previousVideoDiagnostics.droppedFrames),
                maxArrivalGapMilliseconds: video.maxArrivalGapMilliseconds),
            audio: .init(
                packetsPerSecond: rate(audio.packets, previousAudioDiagnostics.packets),
                rejectedPacketsPerSecond: rate(
                    audio.rejectedPackets, previousAudioDiagnostics.rejectedPackets),
                bufferedMilliseconds: audio.bufferedMilliseconds,
                underrunsPerSecond: rate(audio.underruns, previousAudioDiagnostics.underruns),
                droppedFramesPerSecond: rate(
                    audio.droppedFrames, previousAudioDiagnostics.droppedFrames),
                megabitsPerSecond: megabits(audio.bytes, previousAudioDiagnostics.bytes),
                lostPacketsPerSecond: rate(
                    audio.lostPackets, previousAudioDiagnostics.lostPackets),
                maxArrivalGapMilliseconds: audio.maxArrivalGapMilliseconds),
            renderer: .init(
                presentFPS: renderer.presentFPS,
                queuedFrames: renderer.queuedFrames,
                droppedFramesPerSecond: rate(
                    renderer.droppedFrames, previousRendererDiagnostics.droppedFrames),
                gpuBehind: renderer.gpuBehind),
            recording: .init(
                active: isRecording,
                filtered: activeRecordingMode == .filtered,
                queuedVideoFrames: recording.queuedVideoFrames,
                droppedVideoFramesPerSecond: rate(
                    recording.droppedVideoFrames,
                    previousRecordingDiagnostics.droppedVideoFrames),
                droppedAudioPacketsPerSecond: rate(
                    recording.droppedAudioPackets,
                    previousRecordingDiagnostics.droppedAudioPackets)),
            buffering: buffering,
            debug: .init(megabitsPerSecond: debugRate))
        streamDiagnostics.publish(snapshot)
        updateStreamHealthLog(snapshot)
        previousVideoDiagnostics = video
        previousAudioDiagnostics = audio
        previousRendererDiagnostics = renderer
        previousRecordingDiagnostics = recording
        lastDiagnosticsSample = now
    }

    /// Logs only while connected, so an idle viewer does not fill the disk
    /// with zero rows.
    private func updateStreamHealthLog(_ snapshot: StreamDiagnosticsSnapshot) {
        guard settings.streamHealthLogEnabled, isConnected else {
            if streamHealthLog != nil {
                streamHealthLog = nil
                streamDiagnostics.logURL = nil
            }
            return
        }
        if streamHealthLog == nil {
            streamHealthLog = try? StreamHealthLog(deviceName: device.name)
            streamDiagnostics.logURL = streamHealthLog?.url
        }
        do {
            try streamHealthLog?.append(snapshot)
        } catch {
            // Disk full or file removed: stop logging rather than crash.
            // The toggle stays on, so the next sample opens a fresh file.
            streamHealthLog = nil
            streamDiagnostics.logURL = nil
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
    private var reconnectTaskID: UUID?
    private var connectionRetryAllowed = false
    @Published private(set) var isReconnecting = false

    private func startHealthMonitor() {
        healthMonitor = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                guard self.isConnected else { consecutiveFailures = 0; continue }
                let probe = UltimateAPIClient(device: self.device, timeout: 3, transport: self.transport)
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
        // `startDebugTrace` can be suspended in a REST request or its
        // stop/settle/start delay. Invalidate that work before changing to
        // `.connecting`, because debug startup otherwise treats reconnecting
        // as a valid state and can reopen its receiver against a stale link.
        connectionGeneration &+= 1
        debugPrewarmTask?.cancel()
        debugPrewarmTask = nil
        stopRecording()
        videoReceiver.stop()
        audioReceiver.stop()
        debugStreamReceiver.stop()
        debugTraceConsumers.removeAll()
        debugTraceState = .inactive
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
    private func cancelReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectTaskID = nil
        isReconnecting = false
    }

    private func startReconnectLoop(requiresPreference: Bool = true) {
        cancelReconnectLoop()
        let id = UUID()
        reconnectTaskID = id
        isReconnecting = true
        reconnectTask = Task { [weak self] in
            var delaySeconds = 2.0
            defer {
                if let self, self.reconnectTaskID == id {
                    self.reconnectTask = nil
                    self.reconnectTaskID = nil
                    self.isReconnecting = false
                }
            }
            while !Task.isCancelled {
                // Back off before retrying. A session/setting change during
                // sleep must not start another request or resurrect a receiver.
                do { try await Task.sleep(for: .seconds(delaySeconds)) }
                catch { return }
                guard let self, self.reconnectTaskID == id,
                      (!requiresPreference || self.settings.reconnectAutomatically), !self.isConnected,
                      !Task.isCancelled else { return }
                if self.connecting { continue }
                await self.connect(cancelReconnectTask: false)
                guard !Task.isCancelled, !self.isConnected,
                      self.connectionRetryAllowed else { return }
                delaySeconds = min(delaySeconds * 1.5, 30)
            }
        }
    }

    /// Reachability probe: can the device answer its REST API at all?
    /// Two quick attempts (the "2 pings") with a short timeout each.
    /// Returns the device info on success so connect doesn't re-fetch it.
    func probeReachability() async -> UltimateAPIClient.DeviceInfo? {
        let probeClient = UltimateAPIClient(device: device, timeout: 2, transport: transport)
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return nil }
            if let info = try? await probeClient.fetchInfo(), !Task.isCancelled { return info }
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

    private enum PortConfigurationError: LocalizedError {
        case invalid(String, Int)
        case duplicate

        var errorDescription: String? {
            switch self {
            case .invalid(let name, let value):
                return "\(name) port \(value) is outside 1...65535."
            case .duplicate:
                return "Video, Audio, and Debug ports must be different."
            }
        }
    }

    private func validatedLocalPort(
        _ value: Int,
        name: String
    ) throws -> UInt16 {
        guard let port = UInt16(exactly: value), port > 0 else {
            throw PortConfigurationError.invalid(name, value)
        }
        return port
    }

    private func validateLocalPortSet() throws {
        let ports = [device.videoPort, device.audioPort, device.debugPort]
        guard Set(ports).count == ports.count else {
            throw PortConfigurationError.duplicate
        }
        _ = try validatedLocalPort(device.videoPort, name: "Video")
        _ = try validatedLocalPort(device.audioPort, name: "Audio")
        _ = try validatedLocalPort(device.debugPort, name: "Debug")
    }

    // MARK: - Connection lifecycle

    private var connecting = false
    /// Every connect/disconnect transition invalidates older async work.
    /// `connect()` has several network sleeps/awaits; without this token an
    /// old attempt can resume after Disconnect and recreate receivers or set
    /// the session back to Connected.
    private var connectionGeneration: UInt64 = 0
    /// Stable identity for SessionManager remote-stream ownership checks —
    /// a stale `disconnect(stopRemoteStreams:)` must not stop a replacement
    /// session's streams on the same device id.
    let instanceID = UUID()
    /// Single-flight gate for stop/settle/start so recover + silent-watch +
    /// restartStreams cannot interleave host-resolve races on the Ultimate.
    private var streamingOp: Task<Void, Error>?
    private var streamingOpID: UInt64 = 0
    /// Resolved video/audio parameters of the current in-flight streaming op.
    /// Concurrent callers read these before yielding to the op so they can
    /// decide whether to start a follow-up op for any streams the op missed.
    private var streamingOpVideo = false
    private var streamingOpAudio = false

    private func isCurrentConnection(_ generation: UInt64) -> Bool {
        connectionGeneration == generation
    }

    private func abandonStaleConnectionAttempt() {
        videoReceiver.stop()
        audioReceiver.stop()
        debugStreamReceiver.stop()
    }

    func connect(cancelReconnectTask: Bool = true) async {
        guard !connecting, !Task.isCancelled else { return }
        // Manual connect/retry supersedes an automatic loop. Automatic loop
        // attempts pass false so they do not self-cancel before their first
        // throwing suspension point.
        if cancelReconnectTask {
            cancelReconnectLoop()
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
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionRetryAllowed = false
        defer {
            connecting = false
            if cancelReconnectTask, connectionRetryAllowed,
               isCurrentConnection(generation), !Task.isCancelled,
               settings.reconnectAutomatically {
                startReconnectLoop()
            }
        }
        // Explicit reconnect after a disconnect must restore health monitoring.
        if healthMonitor == nil { startHealthMonitor() }
        if stalenessMonitor == nil { startStreamStalenessMonitor() }
        if diagnosticsMonitor == nil { startDiagnosticsMonitor() }

        state = .connecting
        cancelPowerOffVisualEffect?()
        streamsStoppedByUser = false
        fps = 0
        isStreaming = false

        // A newly booting device may miss both initial probes. Keep the
        // unreachable state informative and schedule retries when enabled.
        guard let info = await probeReachability() else {
            if isCurrentConnection(generation), !Task.isCancelled {
                connectionRetryAllowed = true
                state = .unreachable
            }
            return
        }
        guard isCurrentConnection(generation), !Task.isCancelled else { return }
        reportedProduct = info.product ?? info.displayProduct
        let description = info.connectionDescription
        do {
            // Start local UDP receivers first so no packets are dropped.
            try validateLocalPortSet()
            refreshNetworkRoute()
            videoReceiver.playoutDelaySeconds = settings.videoPlayoutDelaySeconds(onWiFi: reachesDeviceOverWiFi)
            try videoReceiver.start(port: try validatedLocalPort(
                device.videoPort, name: "Video"))
            let audioOK = await startAudioIfEnabled()
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
                guard isCurrentConnection(generation) else {
                    abandonStaleConnectionAttempt()
                    return
                }
                videoLive = videoReceiver.packetsReceived > videoPacketBaseline
                audioLive = audioReceiver.packetsReceived > audioPacketBaseline
                if videoLive && (audioLive || !settings.audioEnabled) { break }
            }

            if !videoLive || (settings.audioEnabled && !audioLive) {
                do {
                    try await startStreaming(
                        video: !videoLive,
                        audio: settings.audioEnabled && !audioLive,
                        generation: generation)
                    guard isCurrentConnection(generation) else {
                        abandonStaleConnectionAttempt()
                        return
                    }
                } catch where error.localizedDescription.contains("Network Host Resolve Error") {
                    // Transient wedge: the stack often accepts the same
                    // request moments later. Retry once.
                    try await Task.sleep(for: .seconds(1))
                    guard isCurrentConnection(generation) else {
                        abandonStaleConnectionAttempt()
                        return
                    }
                    try await startStreaming(
                        video: !videoLive,
                        audio: settings.audioEnabled && !audioLive,
                        generation: generation)
                    guard isCurrentConnection(generation) else {
                        abandonStaleConnectionAttempt()
                        return
                    }
                }
            }

            guard isCurrentConnection(generation) else {
                abandonStaleConnectionAttempt()
                return
            }
            state = .connected(
                info: description.isEmpty ? device.displayAddress : description)
            // These are not required to show the live picture. Run them
            // asynchronously so restarting the app reconnects promptly;
            // SID playback itself awaits the debug task below.
            inputPrepareTask = Task { [weak self] in await self?.input.prepare() }
            beginDebugPrewarm()
            if !audioOK {
                recoverAudioQuietly()
            }
            watchForSilentStream()
            // SID windows may still be open from before disconnect — re-arm
            // register-write / audio-tap paths that suspendForSessionTeardown cleared.
            SIDEngine.existing(for: device.id)?.resumeAfterSessionConnect()
        } catch {
            guard isCurrentConnection(generation) else {
                abandonStaleConnectionAttempt()
                return
            }
            videoReceiver.stop()
            audioReceiver.stop()
            connectionRetryAllowed = !(error is PortConfigurationError) && !Task.isCancelled
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
    private func startAudioIfEnabled() async -> Bool {
        guard settings.audioEnabled else { return true }
        audioReceiver.volume = Float(settings.volume)
        audioReceiver.bufferSeconds = settings.effectiveAudioBufferSeconds(onWiFi: reachesDeviceOverWiFi)
        audioReceiver.preferredOutputDeviceUID = settings.audioOutputDeviceUID
        audioReceiver.rfAudioEnabled = display.tubeInput == .rf && isCRTFilterActive
        do {
            try await audioReceiver.start(port: try validatedLocalPort(
                device.audioPort, name: "Audio"))
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
                if await self.startAudioIfEnabled() { return }
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

    private func cancelStreamLifecycleTasks() {
        streamRecoveryTask?.cancel()
        streamRecoveryTask = nil
        silentStreamWatchTask?.cancel()
        silentStreamWatchTask = nil
        silentDebugWatchTask?.cancel()
        silentDebugWatchTask = nil
    }

    private func recoverStaleStreams() {
        guard isConnected,
              !streamsStoppedByUser,
              streamRecoveryTask == nil else { return }
        let generation = connectionGeneration
        streamRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.streamRecoveryTask != nil {
                    self.streamRecoveryTask = nil
                }
            }
            for attempt in 0..<2 where !Task.isCancelled {
                do {
                    try await self.startStreaming(generation: generation)
                    guard !Task.isCancelled,
                          self.isCurrentConnection(generation),
                          self.isConnected,
                          !self.streamsStoppedByUser else { return }
                    self.watchForSilentStream(attempt: attempt, generation: generation)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          self.isCurrentConnection(generation),
                          self.isConnected,
                          !self.streamsStoppedByUser else { return }
                    if attempt == 0 {
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            guard !Task.isCancelled,
                  self.isCurrentConnection(generation),
                  self.isConnected,
                  !self.streamsStoppedByUser else { return }
            self.transferStatus = .failed(
                "The stream stopped and could not be re-armed automatically.")
        }
    }

    /// After connect, verify frames actually arrive. The device sometimes
    /// acknowledges stream-start without sending packets (notably right
    /// after a cold power-on); one stop/start re-kick fixes it. Bounded to
    /// a few attempts so a genuinely broken path still surfaces as an error.
    private func watchForSilentStream(
        attempt: Int = 0,
        generation: UInt64? = nil
    ) {
        let generation = generation ?? connectionGeneration
        silentStreamWatchTask?.cancel()
        silentStreamWatchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentConnection(generation),
                  self.isConnected,
                  !self.streamsStoppedByUser else { return }
            if self.fps < 1 {
                if attempt < 2 {
                    do {
                        try await self.startStreaming(generation: generation)
                    } catch is CancellationError {
                        return
                    } catch {
                        // Fall through to the next attempt / error surface.
                    }
                    guard !Task.isCancelled,
                          self.isCurrentConnection(generation),
                          self.isConnected,
                          !self.streamsStoppedByUser else { return }
                    self.watchForSilentStream(attempt: attempt + 1, generation: generation)
                } else {
                    self.transferStatus = .failed(
                        "No video arriving. Ultimate 64 A/V streams use the "
                            + "wired Ethernet interface even when REST works "
                            + "over Wi-Fi; verify the cable and use the wired "
                            + "IP address. Also check the firewall/UDP path.")
                }
            }
        }
    }

    /// Ask the Ultimate to send its video/audio streams to this Mac's
    /// address. Streams stop on the device side after a reboot or when a
    /// configured stream duration expires — call this to (re)start them
    /// without tearing down the local receivers.
    ///
    /// Concurrent callers share one in-flight stop/settle/start; overlapping
    /// cycles wedge C64 Ultimate 1.1.0 with "Network Host Resolve Error".
    func startStreaming(
        video: Bool = true,
        audio: Bool? = nil,
        generation: UInt64? = nil
    ) async throws {
        let generation = generation ?? connectionGeneration
        guard isConnected || connecting, isCurrentConnection(generation) else {
            throw CancellationError()
        }
        if let streamingOp {
            // Snapshot in-flight params before yielding so we can decide
            // after the op finishes whether our streams were covered.
            let opVideo = streamingOpVideo
            let opAudio = streamingOpAudio
            try await streamingOp.value
            guard isCurrentConnection(generation),
                  isConnected || connecting else {
                throw CancellationError()
            }
            // Only skip a follow-up op if the in-flight op already started
            // every stream the caller requested. When the caller requested
            // video but the op didn't, or audio but the op didn't, fall
            // through to launch a new op with the correct parameters.
            let myAudio = audio ?? settings.audioEnabled
            if (!video || opVideo) && (!myAudio || opAudio) { return }
        }
        let resolvedAudio = audio ?? settings.audioEnabled
        streamingOpVideo = video
        streamingOpAudio = resolvedAudio
        streamingOpID &+= 1
        let opID = streamingOpID
        let op = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performStartStreaming(
                video: video, audio: audio, generation: generation)
        }
        streamingOp = op
        defer {
            if streamingOpID == opID { streamingOp = nil }
        }
        try await op.value
    }

    private func performStartStreaming(
        video: Bool,
        audio: Bool?,
        generation: UInt64
    ) async throws {
        guard isConnected || connecting, isCurrentConnection(generation) else {
            throw CancellationError()
        }
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
        guard isCurrentConnection(generation),
              isConnected || connecting else {
            throw CancellationError()
        }
        if video || startAudio {
            try await Task.sleep(for: .seconds(1))
        }
        // The restarted streams renumber their packets and frames.
        if video { videoReceiver.resetSequenceTracking() }
        if startAudio { audioReceiver.resetSequenceTracking() }
        guard isCurrentConnection(generation),
              isConnected || connecting else {
            throw CancellationError()
        }
        if video {
            try await client.startVideoStream(
                destinationHost: localIP,
                port: device.videoPort,
                durationSeconds: settings.streamDurationSeconds)
        }
        guard isCurrentConnection(generation),
              isConnected || connecting else {
            throw CancellationError()
        }
        if startAudio {
            try await client.startAudioStream(
                destinationHost: localIP,
                port: device.audioPort,
                durationSeconds: settings.streamDurationSeconds)
        }
        // C64 Ultimate Founder (1.1.0) silently stops the debug bus-trace
        // whenever VIC is stop/started. U64-II keeps debug running, but
        // re-asserting an already-live destination is harmless there and
        // restores SID/Debug Trace after video watchdog re-arms.
        await reassertDebugStreamIfNeeded(generation: generation)
    }

    /// startStreaming for UI call sites: failures surface in `state`.
    func restartStreams() async {
        streamsStoppedByUser = false
        let generation = connectionGeneration
        await run { try await self.startStreaming(generation: generation) }
        guard isCurrentConnection(generation), isConnected else { return }
        watchForSilentStream(generation: generation)
    }

    /// Ask the device to stop sending streams, keeping the session (REST
    /// control, keyboard, file loading) alive. Counterpart of
    /// restartStreams; the picture freezes on the last received frame.
    func stopStreams() async {
        stopRecording()
        streamsStoppedByUser = true
        cancelStreamLifecycleTasks()
        try? await client.stopVideoStream()
        try? await client.stopAudioStream()
        resetFrameStats()
        isVideoGPUBehind = false
        isStreaming = false
    }

    func disconnect(
        stopRemoteStreams: Bool = true,
        waitForInputRelease: Bool = true,
        /// When provided, remote stop runs only while this returns true
        /// (SessionManager uses it so a replacement session is not killed).
        stillOwnsRemote: (() -> Bool)? = nil
    ) async {
        // Single teardown path — do not bump generation here; prepareForEviction
        // owns that (and is idempotent when SessionManager already called it).
        prepareForEviction()
        if waitForInputRelease {
            await input.cancelAndRelease()
        } else {
            // App quit must not stall on release-all retries to a dead host.
            Task { await input.cancelAndRelease() }
        }
        if stopRemoteStreams {
            let owns = stillOwnsRemote?() ?? true
            if owns {
                try? await client.stopVideoStream()
            }
            if stillOwnsRemote?() ?? owns {
                try? await client.stopAudioStream()
            }
            if stillOwnsRemote?() ?? owns {
                try? await client.stopDebugStream()
            }
        }
    }

    /// Synchronous half of disconnect used by SessionManager eviction.
    /// Releases local ports and cancels lifecycle tasks before a replacement
    /// DeviceSession can be constructed; remote stop requests finish in the
    /// asynchronous `disconnect()` tail. Idempotent: a second call after
    /// locals are already down does not bump `connectionGeneration` again.
    func prepareForEviction() {
        sidPlayback.beginPlayback()
        stopRecording()
        let needsInvalidate = state != .disconnected
            || streamingOp != nil
            || reconnectTask != nil
            || healthMonitor != nil
            || stalenessMonitor != nil
        if needsInvalidate {
            connectionGeneration &+= 1
        }
        streamingOp?.cancel()
        streamingOp = nil
        cancelReconnectLoop()
        healthMonitor?.cancel()
        healthMonitor = nil
        diagnosticsMonitor?.cancel()
        diagnosticsMonitor = nil
        stalenessMonitor?.cancel()
        stalenessMonitor = nil
        cancelStreamLifecycleTasks()
        // Suspend open SID engines before stopping receivers so sticky
        // `registerWritesEnabled` cannot block re-acquire after reconnect.
        SIDEngine.existing(for: device.id)?.suspendForSessionTeardown()
        if case .active(let mode) = debugTraceState {
            reconnectDebugTraceMode = mode
        } else if debugTraceState == .starting || !debugTraceConsumers.isEmpty {
            reconnectDebugTraceMode = .cpu6510Only
        }
        videoReceiver.stop()
        audioReceiver.stop()
        debugStreamReceiver.stop()
        debugTraceConsumers.removeAll()
        warmDebugTraceLease = nil
        inputPrepareTask?.cancel()
        inputPrepareTask = nil
        debugPrewarmTask?.cancel()
        debugPrewarmTask = nil
        debugTraceState = .inactive
        resetFrameStats()
        isVideoGPUBehind = false
        isPaused = false
        state = .disconnected
    }

    private func resetFrameStats() {
        fps = 0
        presentFPS = 0
        videoFrameStats.streamFPS = 0
        videoFrameStats.presentFPS = 0
    }

    // MARK: - Debug bus-trace stream

    /// Silent, best-effort probe for U64 debug register support. Never
    /// surfaces as a connection error — hardware/firmware without this
    /// register simply fails this and keeps the debug features hidden.
    private func probeDebugCapability() async {
        let probeClient = UltimateAPIClient(device: device, timeout: 3, transport: transport)
        let supported = (try? await probeClient.readDebugRegister()) != nil
        guard isConnected || connecting else { return }
        supportsDebugFeatures = supported
        if supported, settings.keepDebugStreamWarm {
            await enableWarmDebugTrace()
        }
    }

    private func beginDebugPrewarm() {
        debugPrewarmTask?.cancel()
        debugPrewarmTask = Task { [weak self] in
            guard let self else { return }
            await self.probeDebugCapability()
            guard let mode = self.reconnectDebugTraceMode,
                  self.supportsDebugFeatures,
                  self.isConnected
            else { return }
            self.reconnectDebugTraceMode = nil
            if case .active(let activeMode) = self.debugTraceState,
               activeMode == mode {
                return
            }
            await self.startDebugTrace(mode: mode)
        }
    }

    private func awaitDebugPrewarmBeforeSIDPlayback() async {
        guard settings.keepDebugStreamWarm else { return }
        if let debugPrewarmTask {
            await debugPrewarmTask.value
        } else {
            await probeDebugCapability()
        }
    }

    /// Called after debug capability detection and when the preference changes.
    /// Unsupported hardware never receives a debug:start request.
    func updateDebugStreamWarmPreference() {
        guard (isConnected || connecting), supportsDebugFeatures else { return }
        if settings.keepDebugStreamWarm {
            Task { await self.enableWarmDebugTrace() }
        } else {
            disableWarmDebugTrace()
        }
    }

    private func enableWarmDebugTrace() async {
        guard warmDebugTraceLease == nil else { return }
        guard (isConnected || connecting),
              settings.keepDebugStreamWarm,
              supportsDebugFeatures
        else { return }
        warmDebugTraceLease = await acquireDebugTrace(mode: .cpu6510Only)
    }

    private func disableWarmDebugTrace() {
        guard let lease = warmDebugTraceLease else { return }
        warmDebugTraceLease = nil
        Task { [weak self] in
            await self?.releaseDebugTrace(lease)
        }
    }

    /// Start the debug bus-trace stream in `mode`, alongside whatever
    /// video/audio streaming is already happening.
    ///
    /// Ultimate's documentation claims the debug and video streams are
    /// mutually exclusive on the shared 100 Mbps link ("turning on the
    /// video stream will automatically turn off the debug stream"). Live
    /// testing against a real U64-II (firmware 3.15) disproved this in
    /// both directions: starting the debug stream while video/audio were
    /// already running did not interrupt them, and (re)starting video
    /// while the debug stream was running did not interrupt that either —
    /// all three kept delivering packets simultaneously. So this
    /// deliberately does **not** touch the video/audio streams at all.
    func startDebugTrace(mode: DebugStreamMode) async {
        guard isConnected || connecting else { return }
        reconnectDebugTraceMode = mode
        let generation = connectionGeneration
        debugTraceState = .starting
        debugLifecycleLog(
            "[Stream64 debug] start requested mode=\(mode.rawValue) "
                + "consumers=\(debugTraceConsumers.count) "
                + "packets=\(debugStreamReceiver.packetsReceived)")
        guard let localIP = LocalNetwork.primaryIPv4Address(reachingDevice: device.host) else {
            debugTraceState = .error("Could not determine this Mac's address on the Ultimate's network.")
            return
        }

        do {
            // Mode selection is a config item, not the debug register.
            // Only write it when a different source is requested; rewriting
            // the current value can disrupt live SID/RSID playback.
            try await client.ensureDebugStreamMode(mode)
                guard isCurrentConnection(generation), isConnected || connecting else {
                debugStreamReceiver.stop()
                if isCurrentConnection(generation) {
                    debugTraceState = .inactive
                }
                return
            }
            debugStreamReceiver.source = mode.decodeSource
            try debugStreamReceiver.start(port: try validatedLocalPort(
                device.debugPort, name: "Debug"))
            // C64 Ultimate Founder / early 1.0 (still reported as "3.14")
            // rejects a bare debug:start with "Network Host Resolve Error"
            // unless the previous destination is torn down first — same
            // stop → settle → start dance as VIC/audio on that line.
            try await startDebugStreamWithSettle(
                destinationHost: localIP,
                port: device.debugPort,
                generation: generation)
            guard isCurrentConnection(generation), isConnected || connecting else {
                debugStreamReceiver.stop()
                try? await client.stopDebugStream()
                if isCurrentConnection(generation) {
                    debugTraceState = .inactive
                }
                return
            }
            debugTraceState = .active(mode)
            debugLifecycleLog(
                "[Stream64 debug] active mode=\(mode.rawValue) "
                    + "packets=\(debugStreamReceiver.packetsReceived)")
            watchForSilentDebugStream(generation: generation)
        } catch {
            debugStreamReceiver.stop()
            if isCurrentConnection(generation) {
                debugTraceState = .error(error.localizedDescription)
            }
            debugLifecycleLog(
                "[Stream64 debug] start failed: \(error.localizedDescription)")
        }
    }

    /// Start the device debug stream, retrying once with stop/settle when
    /// firmware returns the C64U-style host-resolve wedge.
    private func startDebugStreamWithSettle(
        destinationHost: String,
        port: Int,
        generation: UInt64
    ) async throws {
        do {
            try await client.startDebugStream(
                destinationHost: destinationHost, port: port)
            return
        } catch {
            guard isHostResolveError(error) else { throw error }
        }
        guard isCurrentConnection(generation), isConnected || connecting else {
            throw CancellationError()
        }
        try? await client.stopDebugStream()
        try await Task.sleep(for: .seconds(1))
        guard isCurrentConnection(generation), isConnected || connecting else {
            throw CancellationError()
        }
        try await client.startDebugStream(
            destinationHost: destinationHost, port: port)
    }

    /// Re-issue debug:start when Stream64 still expects a live bus-trace.
    /// Founder firmware drops debug whenever video is restarted; without this
    /// SID visualizations and Debug Trace go quiet while `debugTraceState`
    /// remains `.active`.
    private func reassertDebugStreamIfNeeded(generation: UInt64) async {
        guard isCurrentConnection(generation), isConnected || connecting else {
            return
        }
        guard supportsDebugFeatures else { return }
        let shouldRun = !debugTraceConsumers.isEmpty
            || warmDebugTraceLease != nil
            || {
                if case .active = debugTraceState { return true }
                return false
            }()
        guard shouldRun else { return }

        let mode: DebugStreamMode = {
            if case .active(let active) = debugTraceState { return active }
            return reconnectDebugTraceMode ?? .cpu6510Only
        }()

        switch debugTraceState {
        case .active:
            guard let localIP = LocalNetwork.primaryIPv4Address(
                reachingDevice: device.host) else { return }
            do {
                // Founder often accepts a bare debug:start (HTTP 200) after
                // VIC re-arm but emits no packets until stop → settle → start.
                try? await client.stopDebugStream()
                try await Task.sleep(for: .seconds(1))
                guard isCurrentConnection(generation),
                      isConnected || connecting else { return }
                try await client.startDebugStream(
                    destinationHost: localIP,
                    port: device.debugPort)
                debugLifecycleLog(
                    "[Stream64 debug] reasserted after video/audio start "
                        + "mode=\(mode.rawValue)")
                watchForSilentDebugStream(generation: generation)
            } catch {
                debugLifecycleLog(
                    "[Stream64 debug] reassert failed: \(error.localizedDescription)")
            }
        case .inactive, .error:
            await startDebugTrace(mode: mode)
        case .starting:
            break
        }
    }

    /// If an "active" debug stream stops delivering packets (common after
    /// Founder VIC re-arms), restart it while consumers still expect a trace.
    private func watchForSilentDebugStream(generation: UInt64? = nil) {
        let generation = generation ?? connectionGeneration
        silentDebugWatchTask?.cancel()
        silentDebugWatchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentConnection(generation),
                  self.isConnected else { return }
            guard case .active = self.debugTraceState else { return }
            guard !self.debugTraceConsumers.isEmpty
                    || self.warmDebugTraceLease != nil else { return }
            let baseline = self.debugStreamReceiver.packetsReceived
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  self.isCurrentConnection(generation),
                  self.isConnected,
                  case .active = self.debugTraceState else { return }
            guard self.debugStreamReceiver.packetsReceived <= baseline else {
                self.watchForSilentDebugStream(generation: generation)
                return
            }
            self.debugLifecycleLog(
                "[Stream64 debug] silent while consumers active — restarting")
            await self.reassertDebugStreamIfNeeded(generation: generation)
        }
    }

    private func isHostResolveError(_ error: Error) -> Bool {
        error.localizedDescription.contains("Network Host Resolve Error")
    }

    private func debugLifecycleLog(_ message: String) {
        guard settings.debugLifecycleLogging else { return }
        NSLog("%@", message)
    }

    /// Acquire shared ownership of the session's debug stream. Multiple
    /// Debug Trace/SID windows can hold leases simultaneously; only the first
    /// starts the device stream. Returns `nil` when the stream cannot be
    /// brought to `.active` — callers must not treat a failed start as a live
    /// lease. If the stream is already active in a different mode and this is
    /// the sole consumer path (no other leases yet), it restarts in `mode`;
    /// otherwise the existing mode is shared and the new lease joins it.
    func acquireDebugTrace(mode: DebugStreamMode) async -> UUID? {
        guard isConnected || connecting else { return nil }
        debugLifecycleLog(
            "[Stream64 debug] acquire mode=\(mode.rawValue) "
                + "state=\(debugTraceState) "
                + "consumers=\(debugTraceConsumers.count) "
                + "packets=\(debugStreamReceiver.packetsReceived)")

        switch debugTraceState {
        case .active(let activeMode) where activeMode != mode:
            if debugTraceConsumers.isEmpty {
                await startDebugTrace(mode: mode)
            }
            // else: join the already-running stream in its current mode
        case .inactive, .error:
            await startDebugTrace(mode: mode)
        case .starting:
            // Another caller is mid start/settle — wait for it rather than
            // returning nil and leaving SID register modes permanently quiet.
            await waitForDebugTraceStart(generation: connectionGeneration)
        case .active:
            break
        }

        guard case .active = debugTraceState else { return nil }
        let token = UUID()
        debugTraceConsumers.insert(token)
        debugLifecycleLog(
            "[Stream64 debug] acquired consumers=\(debugTraceConsumers.count) "
                + "packets=\(debugStreamReceiver.packetsReceived)")
        return token
    }

    private func waitForDebugTraceStart(generation: UInt64) async {
        for _ in 0..<50 {
            guard isCurrentConnection(generation), isConnected else { return }
            switch debugTraceState {
            case .starting:
                try? await Task.sleep(for: .milliseconds(100))
            case .active, .inactive, .error:
                return
            }
        }
    }

    func releaseDebugTrace(_ token: UUID) async {
        guard debugTraceConsumers.remove(token) != nil else { return }
        if debugTraceConsumers.isEmpty {
            await stopDebugTrace()
        }
    }

    /// Stop the debug stream. Video/audio were never touched by
    /// `startDebugTrace`, so there's nothing to restart here.
    func stopDebugTrace() async {
        guard debugTraceState != .inactive else { return }
        silentDebugWatchTask?.cancel()
        silentDebugWatchTask = nil
        try? await client.stopDebugStream()
        debugStreamReceiver.stop()
        debugTraceState = .inactive
        reconnectDebugTraceMode = nil
    }

    // MARK: - Machine control

    func reset() async {
        await flushPendingKeys()
        await run { try await self.client.reset() }
        sidPlayback.beginPlayback()
        machineResetToken = UUID()
    }
    func reboot() async {
        await rebootAndReconnect()
    }

    /// Reboot can drop the HTTP reply, and REST may return before streaming
    /// services are ready. Use the complete connect path with backoff rather
    /// than treating the first successful info poll as a completed reboot.
    func rebootAndReconnect() async {
        let requestedGeneration = connectionGeneration
        await flushPendingKeys()
        guard isCurrentConnection(requestedGeneration), !Task.isCancelled else { return }
        prepareForEviction()
        let generation = connectionGeneration
        state = .connecting
        do {
            try await client.reboot()
        } catch {
            guard isCurrentConnection(generation), !Task.isCancelled else { return }
            let code = (error as? URLError)?.code
            guard code == .networkConnectionLost || code == .timedOut || code == .cannotConnectToHost else {
                state = .error("Reboot failed: \(error.localizedDescription)")
                return
            }
            // A restarting device may close the socket before acknowledging.
        }
        guard isCurrentConnection(generation), !Task.isCancelled else { return }
        machineResetToken = UUID()
        state = .unreachable
        // This explicit command requests reconnection even when automatic
        // recovery is disabled. Disconnect/manual Connect still supersede it.
        startReconnectLoop(requiresPreference: false)
    }

    func powerOff() async {
        do {
            try await client.powerOff()
        } catch {
            state = .error(error.localizedDescription)
            return
        }
        sidPlayback.beginPlayback()
        machineResetToken = UUID()

        if display.filterMode == .crtTube {
            beginPowerOffVisualEffect?()
            audioReceiver.playPowerOffCrackle()
            try? await Task.sleep(for: .milliseconds(900))
        }
        // The device is already powered down; avoid two REST timeouts trying
        // to stop streams on a server that no longer exists.
        await disconnect(stopRemoteStreams: false)
    }
    func menuButton() async {
        // If the firmware menu is already active (for example it was opened
        // physically), open the remote child without toggling device state.
        if let screen = try? await client.fetchMenuScreen() {
            RemoteMenuWindowController.show(
                session: self, screen: screen)
            return
        }

        // menu_screen is read-only and returns 404 while the menu is closed,
        // so toggle the firmware menu first. Capable firmware then opens the
        // API-rendered child automatically; older firmware keeps showing the
        // menu only inside the normal video stream.
        do {
            try await client.menuButton()
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        // Firmware 3.15+ can expose the menu as a 40×25 character/colour
        // matrix. Give the UI a short moment to open, then capability-probe.
        // A persistent 404 means old firmware: keep the existing behavior,
        // where the menu remains visible inside the normal video stream.
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(100))
            if let screen = try? await client.fetchMenuScreen() {
                RemoteMenuWindowController.show(
                    session: self, screen: screen)
                return
            }
        }
    }

    func fetchRemoteMenuScreen() async throws -> UltimateMenuScreen {
        try await client.fetchMenuScreen()
    }

    func closeRemoteMenuFromWindow() async {
        try? await client.menuButton()
    }

    /// Open a Telnet/VT100 window onto the Ultimate's menu system and
    /// Machine Code Monitor — native firmware UI with no REST equivalent
    /// (see `TelnetMonitorWindowController`). User-facing name is
    /// "Ultimate Menu": in everyday use this is mostly a live,
    /// non-interrupting view of the on-screen menu, unlike `menuButton()`
    /// above (the REST-based `menu_button`/`menu_screen` path), which
    /// simulates the physical menu button and pauses the C64 while open.
    func openTelnetMonitor() {
        TelnetMonitorWindowController.show(session: self)
    }

    /// Opens every SID visualization mode at once, each in its own
    /// window tiled into a grid across the screen (see
    /// `SIDOscilloscopeWindowController.showAllInGrid`).
    func openAllSIDVisualizations() {
        SIDOscilloscopeWindowController.showAllInGrid(session: self)
    }

    /// Closes every open SID visualization window for this device.
    func closeAllSIDVisualizations() {
        SIDOscilloscopeWindowController.closeAll(for: device.id)
    }

    /// Saves the current arrangement (mode, position, size) of every
    /// open SID Oscilloscope window for this device, so it can be
    /// restored later with `restoreWindowLayout()` — even after quitting
    /// and relaunching the app. Replaces any previously saved layout for
    /// this device. No-ops when nothing is open, so an accidental Save
    /// cannot clear an existing snapshot.
    func saveWindowLayout() {
        let entries = SIDOscilloscopeWindowController.currentLayout(for: device.id)
        guard !entries.isEmpty else { return }
        SIDWindowLayoutStore.save(
            SIDWindowLayoutSnapshot(entries: entries, savedAt: Date()),
            for: device.id)
    }

    /// Re-opens whatever SID Oscilloscope window arrangement was last
    /// saved with `saveWindowLayout()`, replacing any SID Oscilloscope
    /// windows currently open for this device. Does nothing if nothing's
    /// been saved yet.
    func restoreWindowLayout() {
        guard let snapshot = SIDWindowLayoutStore.load(for: device.id), !snapshot.entries.isEmpty else { return }
        SIDOscilloscopeWindowController.restoreLayout(snapshot.entries, session: self)
    }

    /// Whether a SID Oscilloscope window layout has been saved for this
    /// device — used to disable "Restore Window Layout" when there's
    /// nothing to restore.
    var hasSavedWindowLayout: Bool {
        SIDWindowLayoutStore.hasSavedLayout(for: device.id)
    }

    /// Whether any SID Oscilloscope window is currently open for this
    /// device — used to disable "Save Window Layout" when there's
    /// nothing open to save.
    var hasOpenSIDWindows: Bool {
        SIDOscilloscopeWindowController.hasAnyOpenWindows(for: device.id)
    }

    func togglePause() async {
        do {
            if isPaused {
                try await client.resume()
                isPaused = false
            } else {
                try await client.pause()
                isPaused = true
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Keyboard and joystick input

    func sendKeys(_ text: String) {
        input.tapPETSCII(PETSCII.encode(text))
    }

    func sendKeyCodes(_ codes: [UInt8]) {
        input.tapPETSCII(codes)
    }

    func handleHostKeyDown(_ event: HostKeyInput) -> Bool {
        switch C64HostKeyMapper.action(
            for: event, settings: input.settings) {
        case .key(let binding):
            input.keyDown(
                hostKeyCode: event.keyCode,
                inputs: binding.inputs,
                fallback: binding.fallback,
                holdable: binding.holdable)
            return true
        case .joystick(let direction):
            input.setJoystick(
                source: "keyboard", input: direction, pressed: true)
            return true
        case .toggleJoystick:
            input.toggleJoystickMode()
            return true
        case .toggleJoystickPort:
            input.toggleJoystickPort()
            return true
        case .passthrough:
            return false
        }
    }

    func handleHostKeyUp(_ event: HostKeyInput) -> Bool {
        switch C64HostKeyMapper.action(
            for: event, settings: input.settings) {
        case .key:
            input.keyUp(hostKeyCode: event.keyCode)
            return true
        case .joystick(let direction):
            input.setJoystick(
                source: "keyboard", input: direction, pressed: false)
            return true
        case .toggleJoystick, .toggleJoystickPort:
            return true
        case .passthrough:
            return false
        }
    }

    func handleModifierChange(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        if let joystick = C64HostKeyMapper.joystickModifier(
            keyCode: keyCode,
            modifiers: modifiers,
            enabled: input.settings.joystickEnabled,
            fireKey: input.settings.joystickFireKey
        ) {
            input.setJoystick(
                source: "keyboard-control",
                input: joystick.input,
                pressed: joystick.pressed)
            return true
        }
        guard input.settings.keymap == .positional,
              let matrixKey = C64HostKeyMapper.positionalModifier(
                keyCode: keyCode) else { return false }
        let pressed = !input.isHostKeyHeld(keyCode)
        if pressed {
            input.keyDown(
                hostKeyCode: keyCode, inputs: [matrixKey],
                fallback: nil, holdable: true)
        } else {
            input.keyUp(hostKeyCode: keyCode)
        }
        return true
    }

    /// Abandon queued keystrokes and clear unconsumed keys on the C64 —
    /// used at machine-state boundaries (reset, PRG load) so stale input
    /// can't replay into whatever runs next.
    private func flushPendingKeys() async {
        await input.cancelAndRelease()
    }

    /// Load a dropped file: `.prg`/`.crt` run, `.sid`/tracker modules play,
    /// disk images mount in drive A.
    func loadFile(
        at url: URL,
        mountBehavior: MountBehavior = .mountOnly
    ) async {
        do {
            let data = try Data(contentsOf: url)
            _ = await loadData(
                data, filename: url.lastPathComponent,
                mountBehavior: mountBehavior)
        } catch {
            transferStatus = .failed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Run, mount, or play a file that already resides on Ultimate storage.
    /// Uses REST PUT-by-path and avoids downloading through FTP only to upload
    /// the same bytes back through REST.
    func loadRemoteFile(
        path: String,
        filename: String,
        mountBehavior: MountBehavior = .mountOnly
    ) async {
        let ext: String
        if ManagedFileKind.isMODFilename(filename) {
            ext = "mod"
        } else {
            ext = (filename as NSString).pathExtension.lowercased()
        }
        transferStatus = .uploading(filename)
        do {
            switch ext {
            case "prg":
                sidPlayback.beginPlayback()
                await flushPendingKeys()
                try await client.runPRG(path: path)
                transferStatus = .done("Running \(filename)")
            case "d64", "g64", "d71", "g71", "d81":
                try await client.mountDisk(path: path, type: ext)
                if mountBehavior == .mountAndRun {
                    try await bootMountedDisk()
                    transferStatus = .done("Booting \(filename)")
                } else {
                    transferStatus = .done("Mounted \(filename) in drive A")
                }
            case "sid":
                sidPlayback.beginPlayback()
                // The file is already on Ultimate storage and the REST API
                // has no read-by-path endpoint. Do not guess its topology or
                // mutate hardware routing without inspecting its header.
                await awaitDebugPrewarmBeforeSIDPlayback()
                try await client.playSID(path: path)
                transferStatus = .done(
                    "Playing \(filename) (SID routing was not verified)")
            case "mod":
                sidPlayback.beginPlayback()
                try await client.playMOD(path: path)
                transferStatus = .done("Playing \(filename)")
            case "crt":
                sidPlayback.beginPlayback()
                try await client.runCRT(path: path)
                transferStatus = .done("Running \(filename)")
            default:
                transferStatus = .failed("Unsupported file type: .\(ext)")
                return
            }
            scheduleClearTransferStatus()
        } catch {
            transferStatus = .failed(
                "\(filename): \(error.localizedDescription)")
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
    func loadData(
        _ data: Data,
        filename: String,
        songNumber: Int? = nil,
        onUploadStarted: (() -> Void)? = nil,
        mountBehavior: MountBehavior = .mountOnly
    ) async -> LoadOutcome? {
        let ext: String
        if ManagedFileKind.isMODFilename(filename) {
            ext = "mod"
        } else {
            ext = (filename as NSString).pathExtension.lowercased()
        }
        transferStatus = .uploading(filename)
        onUploadStarted?()
        let outcome: LoadOutcome
        do {
            switch ext {
            case "prg":
                sidPlayback.beginPlayback()
                await flushPendingKeys()
                try await client.runPRG(data: data)
                transferStatus = .done("Running \(filename)")
                outcome = .running(filename)
            case "d64", "g64", "d71", "g71", "d81":
                try await client.mountDisk(data: data, filename: filename, type: ext)
                if mountBehavior == .mountAndRun {
                    try await bootMountedDisk()
                    transferStatus = .done("Booting \(filename)")
                    outcome = .booting(filename)
                } else {
                    transferStatus = .done("Mounted \(filename) in drive A")
                    outcome = .mounted(filename)
                }
            case "sid":
                let playbackGeneration = sidPlayback.beginPlayback()
                await awaitDebugPrewarmBeforeSIDPlayback()
                let header = try? SIDHeader(data: data)
                if let header, header.version >= 3 {
                    if let songNumber, songNumber != header.startSong {
                        transferStatus = .failed(
                            "\(filename): PSID64 cannot yet select subtune \(songNumber).")
                        return nil
                    }
                    transferStatus = .uploading("Converting \(filename) with PSID64")
                    let prg = try await psid64.convert(data, filename: filename)
                    // Complete conversion before interrupting the current tune.
                    // A native player leaves transient SID routing and a skip-reset
                    // flag behind; clear that handoff before applying the new map.
                    await flushPendingKeys()
                    transferStatus = .uploading("Preparing SID routing for \(filename)")
                    try await client.prepareSIDProgramPlayback(for: header)
                    machineResetToken = UUID()
                    await SIDEngine.refreshConfiguration(for: self)
                    try await client.runPRG(data: prg)
                    transferStatus = .done("Playing \(filename) via PSID64")
                } else {
                    // Native playback retains best-effort compatibility with quirky
                    // headers; converted multi-SID playback requires valid routing.
                    if let header {
                        _ = try? await client.ensureSIDRouting(for: header)
                        await SIDEngine.refreshConfiguration(for: self)
                    }
                    try await client.playSID(
                        data: data,
                        filename: filename,
                        songNumber: songNumber)
                    transferStatus = .done("Playing \(filename)")
                }
                sidPlayback.didStart(addresses: header?.requiredSIDAddresses, generation: playbackGeneration)
                outcome = .playing(filename)
            case "mod":
                sidPlayback.beginPlayback()
                let payload = try PowerPacker.decrunchIfNeeded(data)
                if payload.count != data.count {
                    transferStatus = .uploading(
                        "Decrunching \(filename)…")
                }
                try await client.playMOD(data: payload, filename: filename)
                transferStatus = .done("Playing \(filename)")
                outcome = .playing(filename)
            case "zip":
                transferStatus = .uploading("Unpacking \(filename)…")
                let payload = try Assembly64ArchiveInspector.firstSupportedPayload(
                    from: data)
                return await loadData(
                    payload.data,
                    filename: payload.filename,
                    songNumber: songNumber,
                    onUploadStarted: nil,
                    mountBehavior: mountBehavior)
            case "crt":
                sidPlayback.beginPlayback()
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

    /// After a disk mount, reset and inject LOAD"*",8,1 + RUN via the KERNAL
    /// keyboard buffer. There is no Ultimate "mount and run" REST endpoint —
    /// only `POST /v1/drives/a:mount` — so boot is done the same way as
    /// ultimate64: DMA-write `load"*",8,1\rrun\r` in ≤10-byte chunks so RUN
    /// sits in the buffer while LOAD executes. Matrix typing is too easy to
    /// lose during disk activity (Mount & Run would only LOAD).
    private func bootMountedDisk() async throws {
        sidPlayback.beginPlayback()
        await flushPendingKeys()
        try await client.reset()
        // Give BASIC time to come up before typing.
        try await Task.sleep(for: .seconds(3))
        try await client.typeKeys(PETSCII.encode("load\"*\",8,1\rrun\r"))
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

    // MARK: - Movie recording

    /// Prompts for a destination and records either the source stream or the
    /// active Metal-filtered viewer as H.264/AAC in a QuickTime movie.
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            presentRecordingSavePanel()
        }
    }

    private func presentRecordingSavePanel() {
        guard isConnected else {
            transferStatus = .failed("Connect before starting a recording.")
            scheduleClearTransferStatus()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = Self.recordingFilename(for: device.name)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let requestedMode = self.settings.recordingMode
                let filteredSize = requestedMode == .filtered
                    ? self.filteredRecordingOutputSize?(self.settings.filteredRecordingSize)
                    : nil
                let activeMode: RecordingMode = filteredSize == nil ? .source : .filtered
                let outputSize: CGSize
                if let filteredSize {
                    outputSize = filteredSize
                } else {
                    // Source remains a reliable fallback when a view has not
                    // mounted yet (or Metal cannot allocate a target).
                    outputSize = CGSize(
                        width: VideoReceiver.width,
                        height: VideoReceiver.palHeight)
                }
                do {
                    self.recordingController.filteredVideoDelaySeconds =
                        self.settings.videoPlayoutDelaySeconds(
                            onWiFi: self.reachesDeviceOverWiFi) ?? 0
                    let filteredHighQuality = activeMode == .filtered
                        && self.settings.filteredRecordingQuality == .proRes422HQ
                    try self.recordingController.start(
                        url: url, palette: self.display.resolvedPalette,
                        outputSize: outputSize,
                        videoBitRate: activeMode == .filtered
                            ? RecordingController.filteredVideoBitRate
                            : RecordingController.sourceVideoBitRate,
                        videoCodec: filteredHighQuality ? .proRes422HQ : .h264,
                        acceptsIndexedFrames: activeMode == .source,
                        requiresMetalCompatiblePixelBuffers: activeMode == .filtered)
                    if activeMode == .filtered {
                        guard let startFiltered = self.startFilteredRecording,
                              startFiltered(
                                self.settings.filteredRecordingSize,
                                { [weak recorder = self.recordingController] in
                                    recorder?.makeFilteredPixelBuffer()
                                },
                                { [weak recorder = self.recordingController] pixelBuffer in
                                    recorder?.enqueue(pixelBuffer: pixelBuffer)
                                }) else {
                            self.recordingController.stop { _ in }
                            throw RecordingController.RecordingError.cannotStartFilteredRendering
                        }
                    }
                } catch {
                    if activeMode == .filtered {
                        self.stopFilteredRecording?()
                    }
                    throw error
                }
                self.activeRecordingMode = activeMode
                self.isRecording = true
                let label: String
                if activeMode == .filtered,
                   self.settings.filteredRecordingQuality == .proRes422HQ {
                    label = "filtered ProRes"
                } else {
                    label = activeMode == .filtered ? "filtered" : "source"
                }
                self.transferStatus = .uploading(
                    "Recording \(label): \(url.lastPathComponent)")
            } catch {
                self.transferStatus = .failed("Recording failed to start: \(error.localizedDescription)")
                self.scheduleClearTransferStatus()
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if activeRecordingMode == .filtered {
            stopFilteredRecording?()
        }
        activeRecordingMode = nil
        recordingController.stop { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.transferStatus = .done("Saved \(url.lastPathComponent)")
                case .failure(let error):
                    self.transferStatus = .failed("Recording failed: \(error.localizedDescription)")
                }
                self.scheduleClearTransferStatus()
            }
        }
    }

    private static func recordingFilename(for deviceName: String) -> String {
        "\(screenshotFilename(for: deviceName)).mov"
    }

    func applyAudioSettings() {
        audioReceiver.volume = Float(settings.volume)
        audioReceiver.bufferSeconds = settings.effectiveAudioBufferSeconds(onWiFi: reachesDeviceOverWiFi)
        audioReceiver.preferredOutputDeviceUID = settings.audioOutputDeviceUID
        audioReceiver.rfAudioEnabled = display.tubeInput == .rf && isCRTFilterActive
    }

    /// Whether the stream path to the device is Wi-Fi, for automatic
    /// buffering. Refreshed on connect and whenever buffering settings apply.
    let streamRoute = StreamRouteStatus()
    var reachesDeviceOverWiFi: Bool { streamRoute.overWiFi }

    /// Returns true when the path switched between Wi-Fi and wired.
    @discardableResult
    private func refreshNetworkRoute() -> Bool {
        let interface = LocalNetwork.primaryInterface(reachingDevice: device.host)
        let wifi = interface.map { LocalNetwork.isWiFiInterface(named: $0.name) } ?? false
        return streamRoute.update(overWiFi: wifi, interfaceName: interface?.name)
    }

    /// Applies Wi-Fi buffering to a live stream: the picture re-primes at
    /// the new depth and audio follows so the two stay in sync.
    func applyNetworkBuffering() {
        refreshNetworkRoute()
        let delay = settings.videoPlayoutDelaySeconds(onWiFi: reachesDeviceOverWiFi)
        videoReceiver.playoutDelaySeconds = delay
        audioReceiver.bufferSeconds = settings.effectiveAudioBufferSeconds(onWiFi: reachesDeviceOverWiFi)
        // A filtered recording in progress stamps renderer output back by
        // the playout delay; keep it in step when the delay changes.
        recordingController.filteredVideoDelaySeconds = delay ?? 0
    }

    /// The input-signal simulation (including RF audio) only runs when a
    /// CRT filter renders the picture.
    private var isCRTFilterActive: Bool {
        display.filterMode == .crt || display.filterMode == .crtTube
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch is CancellationError {
            // Generation-gated stream work treats disconnect as cancellation;
            // that must not surface as a user-visible session error.
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
