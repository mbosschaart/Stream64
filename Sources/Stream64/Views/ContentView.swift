import SwiftUI

struct ContentView: View {
    @EnvironmentObject var deviceStore: DeviceStore
    @EnvironmentObject var settings: AppSettings

    @EnvironmentObject var sessionManager: SessionManager
    @State private var showingAddDevice = false
    @State private var isFullscreen = false
    @AppStorage("mainViewerSidebarExpanded") private var sidebarExpanded = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var arrowKeyMonitor: Any?
    @State private var mouseMoveMonitor: Any?
    @State private var cursorHideTask: Task<Void, Never>?
    @State private var cursorHidden = false
    @State private var fullscreenWindow: NSWindow?
    @State private var previousAcceptsMouseMovedEvents = false
    @State private var mainViewerWindow: NSWindow?
    @AppStorage("showAllScreens") private var showAllScreens = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DeviceSidebar(showingAddDevice: $showingAddDevice)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if showAllScreens, deviceStore.devices.count > 1 {
                MultiViewerGrid(sessionManager: sessionManager)
                    .toolbar { allScreensToggle }
            } else if let device = deviceStore.selectedDevice {
                ViewerPane(session: sessionManager.session(for: device, settings: settings),
                           isFullscreen: isFullscreen,
                           multiDrop: { url in
                               sessionManager.loadFileOnAllConnected(url)
                           })
                    .id(device.id)
                    .toolbar {
                        if deviceStore.devices.count > 1 { allScreensToggle }
                    }
            } else {
                EmptyStateView(showingAddDevice: $showingAddDevice)
            }
        }
        .background(MainViewerWindowObserver(window: $mainViewerWindow))
        // One audible device at a time, in every view mode. Reapply whenever
        // the mode or selection changes; sessions created later respect it
        // via the same calls in the grid/pane task handlers.
        .onChange(of: showAllScreens) { applyAudioPolicy() }
        .onChange(of: deviceStore.selectedDeviceID) {
            applyAudioPolicy()
            applyVisualizationFollowPolicy()
        }
        .onChange(of: settings.visualizationsAutoFollowSelected) {
            applyVisualizationFollowPolicy()
        }
        .onChange(of: settings.volume) {
            sessionManager.applyGlobalVolume(Float(settings.volume))
        }
        .onChange(of: settings.audioOutputDeviceUID) {
            sessionManager.applyAudioOutputDeviceUID(settings.audioOutputDeviceUID)
        }
        .onChange(of: settings.keepDebugStreamWarm) {
            sessionManager.applyDebugStreamWarmPreference()
        }
        .onAppear {
            columnVisibility = sidebarExpanded ? .all : .detailOnly
            applyAudioPolicy()
            sessionManager.applyAudioOutputDeviceUID(settings.audioOutputDeviceUID)
        }
        .onChange(of: columnVisibility) {
            guard !isFullscreen else { return }
            sidebarExpanded = columnVisibility != .detailOnly
        }
        .toolbar { airPlayToolbar }
        .toolbar(isFullscreen ? .hidden : .automatic, for: .windowToolbar)
        .sheet(isPresented: $showingAddDevice) {
            DeviceEditSheet(mode: .add,
                            suggested: .makeDefault(avoiding: deviceStore.devices)) { newDevice in
                deviceStore.add(newDevice)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addDeviceRequested)) { _ in
            showingAddDevice = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window === mainViewerWindow else { return }
            isFullscreen = true
            columnVisibility = .detailOnly
            installArrowKeyMonitor()
            installCursorAutoHide(in: window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window === mainViewerWindow else { return }
            isFullscreen = false
            columnVisibility = sidebarExpanded ? .all : .detailOnly
            removeArrowKeyMonitor()
            removeCursorAutoHide()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
            cursorHideTask?.cancel()
            showCursorIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            if isFullscreen { scheduleCursorHide() }
        }
        .onDisappear {
            removeArrowKeyMonitor()
            removeCursorAutoHide()
        }
    }

    // MARK: - Fullscreen stream switching

    /// In fullscreen: Escape exits to the previous windowed state, and with
    /// multiple devices ←/→ switch streams. The monitor runs before the
    /// video view can forward those keys to the C64.
    private func installArrowKeyMonitor() {
        guard arrowKeyMonitor == nil else { return }
        arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(
                [.command, .option, .control, .shift])

            // Escape always leaves fullscreen (standard viewer behavior).
            // Consumed here so keyboard capture cannot treat it as RUN/STOP.
            if event.keyCode == 53, modifiers.isEmpty {
                let window = mainViewerWindow ?? NSApp.keyWindow
                if let window, window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                    return nil
                }
            }

            guard deviceStore.devices.count > 1,
                  event.keyCode == 123 || event.keyCode == 124 else {
                return event
            }
            let joystickMode = deviceStore.selectedDevice.map {
                InputSettings.shared(for: $0.id).joystickEnabled
            } ?? false
            if joystickMode {
                guard modifiers == [.option] else { return event }
            } else {
                guard modifiers.isEmpty else { return event }
            }
            switchStream(by: event.keyCode == 124 ? 1 : -1)
            return nil // consumed
        }
    }

    private func removeArrowKeyMonitor() {
        if let monitor = arrowKeyMonitor {
            NSEvent.removeMonitor(monitor)
            arrowKeyMonitor = nil
        }
    }

    // MARK: - Fullscreen cursor auto-hide

    private func installCursorAutoHide(in window: NSWindow) {
        removeCursorAutoHide()
        fullscreenWindow = window
        previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true

        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .mouseMoved) { event in
            guard isFullscreen else { return event }
            showCursorIfNeeded()
            scheduleCursorHide()
            return event
        }
        showCursorIfNeeded()
        scheduleCursorHide()
    }

    private func scheduleCursorHide() {
        cursorHideTask?.cancel()
        guard isFullscreen, NSApp.isActive else { return }
        cursorHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard isFullscreen, NSApp.isActive, !Task.isCancelled else { return }
            hideCursorIfNeeded()
        }
    }

    private func hideCursorIfNeeded() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func showCursorIfNeeded() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    private func removeCursorAutoHide() {
        cursorHideTask?.cancel()
        cursorHideTask = nil
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
        }
        showCursorIfNeeded()
        fullscreenWindow?.acceptsMouseMovedEvents =
            previousAcceptsMouseMovedEvents
        fullscreenWindow = nil
    }

    private func switchStream(by offset: Int) {
        let devices = deviceStore.devices
        guard devices.count > 1 else { return }
        let currentIndex = devices.firstIndex { $0.id == deviceStore.selectedDeviceID } ?? 0
        let next = (currentIndex + offset + devices.count) % devices.count
        deviceStore.selectedDeviceID = devices[next].id
    }

    private func applyAudioPolicy() {
        sessionManager.muteAll(except: deviceStore.selectedDeviceID)
    }

    /// Retarget open SID / Memory Map visualizations when the setting is on.
    /// Sound always follows via `applyAudioPolicy` regardless of this flag.
    private func applyVisualizationFollowPolicy() {
        guard settings.visualizationsAutoFollowSelected,
              let device = deviceStore.selectedDevice else { return }
        let session = sessionManager.session(for: device, settings: settings)
        SIDOscilloscopeWindowController.followSelectedSession(session)
        DebugTraceWindowController.followSelectedSession(session)
    }

    private var allScreensToggle: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Toggle(isOn: $showAllScreens) {
                Label("All Screens", systemImage: "square.grid.2x2")
            }
            .help("Show all devices side by side")
        }
    }

    private var airPlayToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let device = deviceStore.selectedDevice {
                let session = sessionManager.session(for: device, settings: settings)
                WiFiBufferingControl(
                    route: session.streamRoute,
                    apply: { sessionManager.applyNetworkBuffering() })
            }
            AirPlayGlobalControl(
                controller: sessionManager.airPlayOutput)
        }
    }
}

/// Link indicator for the selected device: a Wi-Fi or Ethernet symbol,
/// highlighted while network buffering is active. Clicking overrides the
/// automatic default (on for Wi-Fi, off for Ethernet).
private struct WiFiBufferingControl: View {
    @ObservedObject var route: StreamRouteStatus
    @EnvironmentObject private var settings: AppSettings
    let apply: () -> Void

    private var active: Bool { settings.buffersStream(onWiFi: route.overWiFi) }
    private var interfaceSuffix: String {
        route.interfaceName.map { " (\($0))" } ?? ""
    }

    var body: some View {
        Button {
            settings.networkBufferingMode =
                settings.networkBufferingMode.toggled(onWiFi: route.overWiFi)
            apply()
        } label: {
            Label(
                route.overWiFi ? "Wi-Fi Buffering" : "Wired Buffering",
                systemImage: symbol)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .help(helpText)
    }

    private var symbol: String {
        if route.overWiFi { return active ? "wifi" : "wifi.slash" }
        return "cable.connector"
    }

    private var helpText: String {
        let link = route.overWiFi ? "Wi-Fi" : "Ethernet"
        let state = active
            ? "network buffering \(bufferSeconds)" : "network buffering off"
        let source = settings.networkBufferingMode == .automatic
            ? "default for \(link)" : "your override"
        let action = active ? "turn it off" : "turn it on"
        let advice = route.overWiFi
            ? " An Ethernet cable gives the smoothest stream." : ""
        return "\(link)\(interfaceSuffix): \(state) (\(source)). Click to \(action).\(advice)"
    }

    private var bufferSeconds: String {
        String(format: "%.2g s", settings.networkBufferSeconds)
    }
}

private struct AirPlayGlobalControl: View {
    @ObservedObject var controller: AirPlayOutputController

    var body: some View {
        HStack(spacing: 5) {
            AirPlayRoutePickerView(
                controller: controller,
                identifier: "main-toolbar")
                .frame(width: 28, height: 24)
            Text(controller.state.label)
                .font(.caption)
                .lineLimit(1)
            if controller.externalOutputActive {
                Button {
                    controller.stopAirPlay()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Stop AirPlay and return audio to this Mac")
            }
        }
        .help("Choose an app-wide AirPlay audio receiver")
    }
}

/// Attaches the main-viewer lifecycle directly to its concrete NSWindow.
/// Closing that window means quit the app (SID / Debug Trace / etc. are
/// auxiliaries). SwiftUI often detaches this representable *before*
/// `willClose` is delivered — the observer must survive `window == nil`.
private struct MainViewerWindowObserver: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> MainViewerWindowObservationView {
        let view = MainViewerWindowObservationView()
        view.onWindowChanged = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: MainViewerWindowObservationView,
                      context: Context) {}
}

private final class MainViewerWindowObservationView: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?
    private weak var observedWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var endLiveResizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var liveResizeObserver: NSObjectProtocol?
    private var isQuittingFromViewerClose = false
    private var persistWorkItem: DispatchWorkItem?
    private let workspaceTracker = WorkspaceWindowTracker(
        kind: .mainViewer, removesOnClose: false, upsertOnAttach: false)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            onWindowChanged?(nil)
            return
        }
        guard window !== observedWindow else { return }
        removeObservation()
        observedWindow = window
        onWindowChanged?(window)
        guard let window else { return }
        window.identifier = NSWindow.stream64MainViewerIdentifier
        window.setFrameAutosaveName(NSWindow.stream64MainViewerAutosaveName)
        // Do not upsert on attach — SwiftUI's default launch frame must not
        // overwrite the saved size. Restore applies after splash.
        workspaceTracker.attach(to: window)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.quitBecauseMainViewerClosed()
        }
        endLiveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.observedWindow else { return }
            self.commitMainViewerFrame(window)
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleCommitMainViewerFrame()
        }
        liveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                WorkspaceRestorer.cancelMainViewerFrameRestore()
            }
        }
    }

    deinit {
        removeObservation()
    }

    private func scheduleCommitMainViewerFrame() {
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.observedWindow else { return }
            self.commitMainViewerFrame(window)
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func commitMainViewerFrame(_ window: NSWindow) {
        Task { @MainActor in
            guard !WorkspaceSnapshotStore.isRestoring,
                  !WorkspaceRestorer.isRestoringMainViewerFrame else { return }
            guard window.frame.width >= 900, window.frame.height >= 400 else {
                return
            }
            workspaceTracker.upsertFromWindow()
        }
    }

    private func quitBecauseMainViewerClosed() {
        guard !isQuittingFromViewerClose else { return }
        isQuittingFromViewerClose = true
        persistWorkItem?.cancel()
        if let window = observedWindow {
            // Force-save size even during restore — explicit quit.
            MainViewerFrameStore.save(from: window)
            WorkspaceRestorer.captureAndSave(preferringMainViewer: window)
        }
        removeObservation()
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.sessionManager?.prepareForAppTermination()
        }
        NSApp.terminate(nil)
    }

    private func removeObservation() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        for observer in [closeObserver, endLiveResizeObserver, moveObserver,
                         liveResizeObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        closeObserver = nil
        endLiveResizeObserver = nil
        moveObserver = nil
        liveResizeObserver = nil
        observedWindow = nil
    }
}

// MARK: - Multi-viewer grid

/// Shows every configured device as a live tile. Each tile runs its own
/// session (own UDP ports, own Metal renderer); clicking a tile selects
/// that device, double-clicking opens it in single view.
struct MultiViewerGrid: View {
    let sessionManager: SessionManager
    @EnvironmentObject var deviceStore: DeviceStore
    @EnvironmentObject var settings: AppSettings
    @AppStorage("showAllScreens") private var showAllScreens = true
    @State private var showPowerOffConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 420, maximum: 900), spacing: 12)]

    /// Toolbar / audio / joystick target: the actively selected tile
    /// (falls back to the first device so the bar is never empty).
    private var activeDevice: UltimateDevice? {
        deviceStore.selectedDevice ?? deviceStore.devices.first
    }

    private var activeSession: DeviceSession? {
        guard let device = activeDevice else { return nil }
        return sessionManager.session(for: device, settings: settings)
    }

    var body: some View {
        gridContent
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("All Screens")
            .navigationSubtitle(selectionSubtitle)
            .toolbar { selectedDeviceToolbar }
            .confirmationDialog(
                "Power off \(activeDevice?.name ?? "device")?",
                isPresented: $showPowerOffConfirmation
            ) {
                Button("Power Off", role: .destructive) {
                    guard let session = activeSession else { return }
                    Task { await session.powerOff() }
                }
            }
            .onAppear(perform: ensureSelectionAndInputTarget)
            .onChange(of: deviceStore.selectedDeviceID) {
                if let session = activeSession {
                    GameControllerManager.shared.setTarget(session.input)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .powerOffRequested)) { note in
                guard let target = note.object as? DeviceSession,
                      target === activeSession else { return }
                if settings.confirmDestructiveActions {
                    showPowerOffConfirmation = true
                } else {
                    Task { await target.powerOff() }
                }
            }
    }

    private var selectionSubtitle: String {
        activeDevice.map { "Selected: \($0.name)" } ?? ""
    }

    @ViewBuilder
    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(deviceStore.devices) { device in
                    gridTile(for: device)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func gridTile(for device: UltimateDevice) -> some View {
        let session = sessionManager.session(for: device, settings: settings)
        let isSelected = deviceStore.selectedDeviceID == device.id
        ViewerTile(
            session: session,
            isSelected: isSelected,
            multiDrop: { url in
                sessionManager.loadFileOnAllConnected(url)
            })
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .onTapGesture(count: 2) {
                deviceStore.selectedDeviceID = device.id
                showAllScreens = false
            }
            .onTapGesture {
                deviceStore.selectedDeviceID = device.id
                GameControllerManager.shared.setTarget(session.input)
            }
            .onAppear {
                sessionManager.muteAll(except: deviceStore.selectedDeviceID)
            }
    }

    @ToolbarContentBuilder
    private var selectedDeviceToolbar: some ToolbarContent {
        if let session = activeSession {
            ViewerSessionToolbar(
                session: session,
                showOnScreenKeyboard: nil,
                onRequestPowerOff: {
                    if settings.confirmDestructiveActions {
                        showPowerOffConfirmation = true
                    } else {
                        Task { await session.powerOff() }
                    }
                })
        }
    }

    private func ensureSelectionAndInputTarget() {
        if deviceStore.selectedDeviceID == nil {
            deviceStore.selectedDeviceID = deviceStore.devices.first?.id
        }
        if let session = activeSession {
            GameControllerManager.shared.setTarget(session.input)
        }
    }
}

/// Formats the frame-rate overlay. When present FPS is meaningful and
/// diverges from the UDP receive rate, show both (`stream / display`).
private func fpsOverlayText(stream: Double, present: Double) -> String {
    guard present >= 1, abs(stream - present) >= 3 else {
        return String(format: "%.0f fps", stream)
    }
    return String(format: "%.0f / %.0f fps", stream, present)
}

/// Observes only `VideoFrameStats` so 1 Hz FPS ticks do not rebuild the
/// video host (`ViewerPaneSessionContent` / `ViewerTileContent`).
private struct FPSOverlayLabel: View {
    @ObservedObject var stats: VideoFrameStats

    var body: some View {
        Text(fpsOverlayText(stream: stats.streamFPS, present: stats.presentFPS))
            .font(.caption.monospacedDigit())
            .help("Stream receive rate / display present rate")
    }
}

/// Compact selected-view indicator. Its separate observable keeps the
/// diagnostics' once-per-second updates out of the Metal video host.
private struct StreamHealthOverlay: View {
    @ObservedObject var diagnostics: StreamDiagnostics
    @EnvironmentObject private var settings: AppSettings
    @State private var showingDetails = false

    var body: some View {
        let snapshot = diagnostics.snapshot
        Button {
            showingDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                Label(
                    snapshot.healthLabel,
                    systemImage: snapshot.isDegraded
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(snapshot.isDegraded ? .yellow : .green)
                Text("\(snapshot.totalMegabitsPerSecond, specifier: "%.1f") Mbit/s")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                if snapshot.video.lossRatio > 0 {
                    Text("\(snapshot.video.lossRatio * 100, specifier: "%.1f")% loss")
                        .monospacedDigit()
                        .foregroundStyle(.yellow)
                }
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .padding(6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .help("Stream health — click for details")
        .popover(isPresented: $showingDetails, arrowEdge: .top) {
            StreamDiagnosticsDetail(
                snapshot: snapshot,
                logEnabled: $settings.streamHealthLogEnabled,
                logURL: diagnostics.logURL)
        }
    }
}

private struct StreamDiagnosticsDetail: View {
    let snapshot: StreamDiagnosticsSnapshot
    @Binding var logEnabled: Bool
    let logURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                snapshot.healthLabel,
                systemImage: snapshot.isDegraded
                    ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(snapshot.isDegraded ? .yellow : .green)
            Divider()
            Group {
                Text("Network in  \(snapshot.totalMegabitsPerSecond, specifier: "%.1f") Mbit/s · video \(snapshot.video.megabitsPerSecond, specifier: "%.1f") · audio \(snapshot.audio.megabitsPerSecond, specifier: "%.1f") · debug \(snapshot.debug.megabitsPerSecond, specifier: "%.1f")")
                Text("Packet loss  \(snapshot.video.lossRatio * 100, specifier: "%.1f")% · longest gap \(max(snapshot.video.maxArrivalGapMilliseconds, snapshot.audio.maxArrivalGapMilliseconds), specifier: "%.0f") ms")
                Text("Video  \(snapshot.video.framesPerSecond, specifier: "%.1f") fps · \(snapshot.video.packetsPerSecond, specifier: "%.0f") pkt/s")
                Text("Display  \(snapshot.renderer.presentFPS, specifier: "%.1f") fps · \(snapshot.renderer.queuedFrames) queued")
                Text("Audio  \(snapshot.audio.packetsPerSecond, specifier: "%.0f") pkt/s · \(snapshot.audio.bufferedMilliseconds) ms buffer")
                if snapshot.buffering.enabled {
                    Text("Wi-Fi buffer  \(snapshot.buffering.bufferedFrames)/\(snapshot.buffering.targetFrames) frames · \(snapshot.buffering.concealedFramesPerSecond, specifier: "%.0f") patched/s")
                }
                if snapshot.recording.active {
                    Text("Recording  \(snapshot.recording.filtered ? "filtered" : "source") · \(snapshot.recording.queuedVideoFrames) queued")
                }
            }
            .font(.caption.monospacedDigit())
            if snapshot.video.rejectedPacketsPerSecond > 0
                || snapshot.audio.rejectedPacketsPerSecond > 0 {
                Text("Rejected UDP: video \(snapshot.video.rejectedPacketsPerSecond, specifier: "%.0f")/s · audio \(snapshot.audio.rejectedPacketsPerSecond, specifier: "%.0f")/s")
                    .font(.caption)
            }
            if snapshot.audio.underrunsPerSecond > 0
                || snapshot.audio.droppedFramesPerSecond > 0
                || snapshot.renderer.droppedFramesPerSecond > 0
                || snapshot.recording.droppedVideoFramesPerSecond > 0
                || snapshot.recording.droppedAudioPacketsPerSecond > 0 {
                Text("Loss: audio underruns \(snapshot.audio.underrunsPerSecond, specifier: "%.0f")/s · renderer drops \(snapshot.renderer.droppedFramesPerSecond, specifier: "%.0f")/s")
                    .font(.caption)
                if snapshot.recording.droppedVideoFramesPerSecond > 0
                    || snapshot.recording.droppedAudioPacketsPerSecond > 0 {
                    Text("Recording drops: video \(snapshot.recording.droppedVideoFramesPerSecond, specifier: "%.0f")/s · audio \(snapshot.recording.droppedAudioPacketsPerSecond, specifier: "%.0f")/s")
                        .font(.caption)
                }
            }
            if snapshot.video.lostPacketsPerSecond > 0
                || snapshot.video.droppedFramesPerSecond > 0
                || snapshot.audio.lostPacketsPerSecond > 0 {
                Text("Lost: video \(snapshot.video.lostPacketsPerSecond, specifier: "%.0f") pkt/s (\(snapshot.video.droppedFramesPerSecond, specifier: "%.0f") frames/s) · audio \(snapshot.audio.lostPacketsPerSecond, specifier: "%.0f") pkt/s · reordered \(snapshot.video.reorderedPacketsPerSecond, specifier: "%.0f")/s")
                    .font(.caption)
            }
            if snapshot.debug.megabitsPerSecond > 1 {
                Text("The debug stream is running. On Wi-Fi, turn off \"Keep U64 debug stream running\" in Settings → General unless a trace or SID window needs it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.buffering.underrunsPerSecond > 0 {
                Text("Wi-Fi buffer ran dry; refilling. A larger buffer rides out longer dropouts; an Ethernet cable for this Mac avoids them.")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
            if snapshot.renderer.gpuBehind {
                Text("Display renderer is behind.")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
            Divider()
            Toggle("Log stream health to file", isOn: $logEnabled)
                .font(.caption)
            if let logURL {
                HStack {
                    Text(logURL.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 280, alignment: .leading)
    }
}

/// One live device tile in the grid: video, connection state, name banner.
///
/// Does **not** observe `DeviceSession` itself — fps / presentFPS ticks would
/// rebuild this view and tear down an open right-click menu. Session-driven
/// chrome lives in `ViewerTileContent`.
struct ViewerTile: View {
    let session: DeviceSession
    let isSelected: Bool
    /// Control-drop: deliver the file to every connected stream ("Multi Drop").
    var multiDrop: ((URL) -> Void)?
    @EnvironmentObject var settings: AppSettings
    @State private var showPowerOffConfirmation = false

    var body: some View {
        ViewerTileContent(
            session: session,
            isSelected: isSelected,
            multiDrop: multiDrop)
            .contextMenu {
                StreamContextMenu(
                    session: session,
                    requestPictureControls: {
                        PictureControlsPanelController.show(
                            display: session.display)
                    }
                ) {
                    if settings.confirmDestructiveActions {
                        showPowerOffConfirmation = true
                    } else {
                        Task { await session.powerOff() }
                    }
                }
            }
            .confirmationDialog(
                "Power off \(session.device.name)?",
                isPresented: $showPowerOffConfirmation) {
                Button("Power Off", role: .destructive) {
                    Task { await session.powerOff() }
                }
            }
    }
}

private struct ViewerTileContent: View {
    @ObservedObject var session: DeviceSession
    let isSelected: Bool
    var multiDrop: ((URL) -> Void)?
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            Color.black
            VideoView(session: session)
            tileOverlay
            if isDropTargeted {
                dropHighlight
            }
            if let status = session.transferStatus {
                transferBanner(status)
            }
            // Unobtrusive text overlays in the tile corners: no bar, the
            // picture stays fully visible behind them.
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Text(session.device.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .shadow(color: .black.opacity(0.8), radius: 1)
                    Spacer()
                    if session.display.showFPS, session.isConnected {
                        FPSOverlayLabel(stats: session.videoFrameStats)
                            .foregroundStyle(.green)
                            .shadow(color: .black, radius: 2)
                            .shadow(color: .black.opacity(0.8), radius: 1)
                    }
                }
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(dropBorderColor, lineWidth: tileBorderWidth)
        )
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter { ViewerPane.isDroppableURL($0) }
            guard let url = accepted.first else { return false }
            // Control held at drop time = Multi Drop: every connected stream.
            if NSEvent.modifierFlags.contains(.control), let multiDrop {
                multiDrop(url)
            } else {
                Task { await session.loadFile(at: url) }
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .task {
            if session.device.autoConnect, !session.isConnected {
                await session.connect()
            }
        }
    }

    /// Thick green ring for the active tile so selection is obvious in a
    /// crowded grid; drop-target keeps the accent highlight.
    private var tileBorderWidth: CGFloat {
        if isDropTargeted { return 3 }
        if isSelected { return 4 }
        return 1
    }

    private var dropBorderColor: Color {
        if isDropTargeted { return .accentColor }
        return isSelected ? Color.green : .white.opacity(0.15)
    }

    private var dropHighlight: some View {
        ZStack {
            Color.accentColor.opacity(0.18)
            VStack(spacing: 4) {
                Image(systemName: "arrow.down.doc")
                    .font(.title2)
                Text("Load on \(session.device.name)")
                    .font(.caption.weight(.semibold))
                Text("⌃ drop = all streams")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .allowsHitTesting(false)
    }

    private func transferBanner(_ status: DeviceSession.TransferStatus) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                switch status {
                case .uploading(let name):
                    ProgressView().controlSize(.mini)
                    Text("Uploading \(name)…")
                case .done(let message):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(message)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private var tileOverlay: some View {
        switch session.state {
        case .connecting:
            ProgressView()
        case .unreachable:
            VStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                ConnectionRetryStatus(session: session)
                Text("Unreachable")
                    .font(.caption.weight(.semibold))
                Button("Retry") { Task { await session.connect() } }
                    .controlSize(.small)
            }
            .padding(8)
        case .error(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                ConnectionRetryStatus(session: session)
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Retry") { Task { await session.connect() } }
                    .controlSize(.small)
            }
            .padding(8)
        case .disconnected:
            Button("Connect") { Task { await session.connect() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .connected:
            EmptyView()
        }
    }
}

/// Small status dot + label: Unreachable / Offline / Connecting /
/// Online (API up, no packets) / Streaming (packets flowing).
struct DeviceStatusBadge: View {
    @ObservedObject var session: DeviceSession
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            if !compact {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(label)
    }

    private var label: String {
        switch session.state {
        case .unreachable: return "Unreachable"
        case .disconnected: return "Offline"
        case .connecting: return "Connecting…"
        case .error: return "Error"
        case .connected: return session.isStreaming ? "Streaming" : "Online"
        }
    }

    private var color: Color {
        switch session.state {
        case .unreachable, .error: return .red
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .connected: return session.isStreaming ? .green : .blue
        }
    }
}

// MARK: - Sidebar

struct DeviceSidebar: View {
    @EnvironmentObject var deviceStore: DeviceStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sessionManager: SessionManager
    @Binding var showingAddDevice: Bool
    @State private var deviceToEdit: UltimateDevice?

    var body: some View {
        List(selection: $deviceStore.selectedDeviceID) {
            Section("Devices") {
                ForEach(deviceStore.devices) { device in
                    Label {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.displayAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            DeviceStatusBadge(
                                session: sessionManager.session(for: device, settings: settings),
                                compact: true)
                        }
                    } icon: {
                        Image(systemName: "desktopcomputer")
                    }
                    .tag(device.id)
                    .contextMenu {
                        Button("Edit…") { deviceToEdit = device }
                        Divider()
                        Button("Remove", role: .destructive) {
                            Task {
                                await sessionManager.removeSession(
                                    id: device.id)
                                deviceStore.remove(device)
                            }
                        }
                    }
                }
                .onMove { source, destination in
                    deviceStore.move(fromOffsets: source, toOffset: destination)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    showingAddDevice = true
                } label: {
                    Label("Add Device", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
        }
        .sheet(item: $deviceToEdit) { device in
            DeviceEditSheet(mode: .edit(device)) { updated in
                Task {
                    await sessionManager.removeSession(
                        id: updated.id,
                        clearAudibleSelection: false)
                    deviceStore.update(updated)
                }
            }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @Binding var showingAddDevice: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No Device Selected", systemImage: "display")
        } description: {
            Text("Add a Commodore 64 Ultimate to get started.")
        } actions: {
            Button("Add Device…") { showingAddDevice = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Viewer pane

/// Host for the stream viewer. Does **not** observe `DeviceSession` — fps /
/// presentFPS publishes would rebuild the view and dismiss an open
/// right-click menu mid-selection. Live session chrome lives in
/// `ViewerPaneSessionContent`.
struct ViewerPane: View {
    let session: DeviceSession
    @EnvironmentObject var settings: AppSettings
    var isFullscreen: Bool = false
    /// Control-drop: deliver the file to every connected stream ("Multi Drop").
    var multiDrop: ((URL) -> Void)?
    @State private var showPowerOffConfirmation = false

    init(session: DeviceSession, isFullscreen: Bool = false, multiDrop: ((URL) -> Void)? = nil) {
        self.session = session
        self.isFullscreen = isFullscreen
        self.multiDrop = multiDrop
    }

    static let droppableExtensions: Set<String> = [
        "prg", "d64", "g64", "d71", "g71", "d81", "sid",
        "mod", "crt", "zip",
    ]

    static func isDroppableURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if ManagedFileKind.isMODFilename(name) { return true }
        return droppableExtensions.contains(url.pathExtension.lowercased())
    }

    var body: some View {
        ViewerPaneSessionContent(
            session: session,
            isFullscreen: isFullscreen,
            multiDrop: multiDrop)
            .contextMenu {
                StreamContextMenu(
                    session: session,
                    monitorCaseVisible: false,
                    requestPictureControls: {
                        PictureControlsPanelController.show(display: session.display)
                    }
                ) {
                    if settings.confirmDestructiveActions {
                        showPowerOffConfirmation = true
                    } else {
                        Task { await session.powerOff() }
                    }
                }
            }
            .confirmationDialog(
                "Power off \(session.device.name)?",
                isPresented: $showPowerOffConfirmation) {
                Button("Power Off", role: .destructive) {
                    Task { await session.powerOff() }
                }
            }
    }
}

private struct ViewerPaneSessionContent: View {
    @ObservedObject var session: DeviceSession
    /// This device's own rendering settings — observed so the video host
    /// refreshes when display prefs change. Toolbar observes its own copy.
    @ObservedObject var display: DisplaySettings
    /// Deliberately NOT `@ObservedObject`: joystick/matrix traffic used to
    /// republish `InputSettings` often enough to rebuild this whole host
    /// (including `VideoView`) and starve Metal presents. Toolbar controls
    /// and release-on-change side effects observe input in child views.
    @EnvironmentObject var settings: AppSettings
    var isFullscreen: Bool = false
    var multiDrop: ((URL) -> Void)?
    @State private var isDropTargeted = false
    @State private var showOnScreenKeyboard = false
    @State private var showPowerOffConfirmation = false

    init(session: DeviceSession, isFullscreen: Bool = false, multiDrop: ((URL) -> Void)? = nil) {
        self.session = session
        self.display = session.display
        self.isFullscreen = isFullscreen
        self.multiDrop = multiDrop
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                VideoView(session: session)
                overlay
                if isDropTargeted {
                    dropHighlight
                }
                if let status = session.transferStatus {
                    transferBanner(status)
                }
            }
            if showOnScreenKeyboard && !isFullscreen {
                OnScreenKeyboardView(session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.all, edges: isFullscreen ? .all : [])
        .animation(.easeInOut(duration: 0.2), value: showOnScreenKeyboard)
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter { ViewerPane.isDroppableURL($0) }
            guard let url = accepted.first else { return false }
            // Control held at drop time = Multi Drop: every connected stream.
            if NSEvent.modifierFlags.contains(.control), let multiDrop {
                multiDrop(url)
            } else {
                Task { await session.loadFile(at: url) }
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .toolbar {
            ViewerSessionToolbar(
                session: session,
                showOnScreenKeyboard: $showOnScreenKeyboard,
                onRequestPowerOff: {
                    if settings.confirmDestructiveActions {
                        showPowerOffConfirmation = true
                    } else {
                        Task { await session.powerOff() }
                    }
                })
        }
        .navigationTitle(session.device.name)
        .navigationSubtitle(subtitle)
        .task {
            if session.device.autoConnect, !session.isConnected {
                await session.connect()
            }
        }
        .onChange(of: settings.volume) {
            session.applyAudioSettings()
        }
        .onAppear {
            GameControllerManager.shared.setTarget(session.input)
        }
        .onDisappear {
            session.input.releaseAll()
        }
        .onChange(of: display.tubeInput) {
            session.applyAudioSettings()
        }
        .onChange(of: display.filterMode) {
            session.applyAudioSettings()
        }
        .background {
            // Observes input without invalidating the video host above.
            JoystickInputSideEffects(session: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreenshotRequested)) { _ in
            session.saveScreenshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRecordingRequested)) { _ in
            session.toggleRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .powerOffRequested)) { note in
            guard let target = note.object as? DeviceSession,
                  target === session else { return }
            if settings.confirmDestructiveActions {
                showPowerOffConfirmation = true
            } else {
                Task { await session.powerOff() }
            }
        }
        .confirmationDialog(
            "Power off \(session.device.name)?",
            isPresented: $showPowerOffConfirmation) {
            Button("Power Off", role: .destructive) {
                Task { await session.powerOff() }
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .connecting:
            ProgressView("Connecting…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                ConnectionRetryStatus(session: session)
                Text(message)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Retry") {
                        Task { await session.connect() }
                    }
                    Button("Reboot Device & Retry") {
                        Task { await session.rebootAndReconnect() }
                    }
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 360)
        case .unreachable:
            VStack(spacing: 12) {
                Image(systemName: "wifi.slash")
                    .font(.largeTitle)
                ConnectionRetryStatus(session: session)
                Text("\(session.device.name) is unreachable")
                Text("The device did not respond at \(session.device.displayAddress). Check that it is powered on and on the network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await session.connect() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 380)
        case .disconnected:
            VStack(spacing: 12) {
                Image(systemName: "bolt.slash")
                    .font(.largeTitle)
                Text("Not connected")
                Button("Connect") {
                    Task { await session.connect() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .connected:
            if display.showFPS || display.showStreamDiagnostics {
                VStack {
                    HStack(alignment: .top) {
                        if display.showStreamDiagnostics {
                            StreamHealthOverlay(
                                diagnostics: session.streamDiagnostics)
                                .padding(8)
                        }
                        Spacer()
                        if display.showFPS {
                            FPSOverlayLabel(stats: session.videoFrameStats)
                                .padding(6)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(.green)
                                .padding(8)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var dropHighlight: some View {
        ZStack {
            Color.accentColor.opacity(0.15)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(12)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.largeTitle)
                Text("Drop to load on the C64")
                    .font(.headline)
                Text(".prg / .crt run · .sid / .mod play · .zip unwraps · disks mount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .allowsHitTesting(false)
    }

    private func transferBanner(_ status: DeviceSession.TransferStatus) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                switch status {
                case .uploading(let name):
                    ProgressView().controlSize(.small)
                    Text("Uploading \(name)…")
                case .done(let message):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(message)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: session.transferStatus)
    }

    private var subtitle: String {
        switch session.state {
        case .connected(let info):
            return session.isStreaming ? "\(info) — Streaming" : "\(info) — Online"
        case .connecting: return "Connecting…"
        case .unreachable: return "Unreachable"
        case .error: return "Error"
        case .disconnected: return "Disconnected"
        }
    }

}

/// Shared viewer toolbar used by single-device `ViewerPane` and the All
/// Screens grid. Always targets one concrete `DeviceSession` — in grid
/// mode that is the actively selected tile.
struct ViewerSessionToolbar: ToolbarContent {
    @ObservedObject var session: DeviceSession
    @ObservedObject private var display: DisplaySettings
    @EnvironmentObject private var settings: AppSettings
    /// When nil (All Screens grid), the on-screen keyboard toggle is omitted
    /// — there is no below-tile chrome to host it.
    var showOnScreenKeyboard: Binding<Bool>?
    let onRequestPowerOff: () -> Void

    init(
        session: DeviceSession,
        showOnScreenKeyboard: Binding<Bool>?,
        onRequestPowerOff: @escaping () -> Void
    ) {
        self.session = session
        self.display = session.display
        self.showOnScreenKeyboard = showOnScreenKeyboard
        self.onRequestPowerOff = onRequestPowerOff
    }

    private func displayBinding<T>(
        _ keyPath: ReferenceWritableKeyPath<DisplaySettings, T>
    ) -> Binding<T> {
        Binding(
            get: { display[keyPath: keyPath] },
            set: { display[keyPath: keyPath] = $0 })
    }

    private var isCRTFilter: Bool {
        display.filterMode == .crt || display.filterMode == .crtTube
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            connectionControls
            inputAndDisplayControls
            libraryControls
            toolControls
        } else {
            LegacyViewerSessionToolbar(
                session: session,
                showOnScreenKeyboard: showOnScreenKeyboard,
                onRequestPowerOff: onRequestPowerOff)
        }
    }

    @ToolbarContentBuilder
    private var connectionControls: some ToolbarContent {
        // Keep one stable native toolbar item per control. A mixed group can
        // assign the following button's title to a Menu's overflow entry on
        // macOS 27, and conditional controls must not shift item identities.
        ToolbarItem(id: "viewer.connection") {
            if session.isConnected {
                Button {
                    Task { await session.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
                .help("Disconnect \(session.device.name)")
            } else {
                Button {
                    Task { await session.connect() }
                } label: {
                    Label("Connect", systemImage: "bolt")
                }
                .help("Connect \(session.device.name)")
            }
        }

        ToolbarItem(id: "viewer.streaming") {
            if session.isStreaming {
                Button {
                    Task { await session.stopStreams() }
                } label: {
                    Label("Stop Streaming", systemImage: "stop.circle")
                }
                .help("Stop video/audio for \(session.device.name)")
                .disabled(!session.isConnected)
            } else {
                Button {
                    Task { await session.restartStreams() }
                } label: {
                    Label("Start Streaming", systemImage: "dot.radiowaves.left.and.right")
                }
                .help("Ask \(session.device.name) to stream to this Mac")
                .disabled(!session.isConnected)
            }
        }

        ToolbarItem(id: "viewer.reset") {
            Button {
                Task { await session.reset() }
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Reset \(session.device.name)")
            .disabled(!session.isConnected)
        }

        ToolbarItem(id: "viewer.reboot") {
            Button {
                Task { await session.reboot() }
            } label: {
                Label("Reboot", systemImage: "power.circle")
            }
            .help("Reboot \(session.device.name)")
            .disabled(!session.isConnected)
        }

        ToolbarItem(id: "viewer.pause") {
            Button {
                Task { await session.togglePause() }
            } label: {
                Label(session.isPaused ? "Resume" : "Pause",
                      systemImage: session.isPaused ? "play.fill" : "pause.fill")
            }
            .help(session.isPaused
                  ? "Resume \(session.device.name)"
                  : "Pause \(session.device.name)")
            .disabled(!session.isConnected)
        }

        ToolbarItem(id: "viewer.ultimateMenu") {
            Button {
                session.openTelnetMonitor()
            } label: {
                Label("Ultimate Menu", systemImage: "terminal")
            }
            .help("Open the Ultimate Menu for \(session.device.name)")
            .disabled(!session.isConnected)
        }

        ToolbarItem(id: "viewer.powerOff") {
            Button(action: onRequestPowerOff) {
                Label("Power Off", systemImage: "power")
            }
            .help("Power off \(session.device.name)")
            .disabled(!session.isConnected)
        }

    }

    @ToolbarContentBuilder
    private var inputAndDisplayControls: some ToolbarContent {
        ToolbarItem(id: "viewer.captureKeyboard") {
            Toggle(isOn: $settings.captureKeyboardWhenFocused) {
                Label("Capture Keyboard", systemImage: "keyboard")
            }
            .help(settings.captureKeyboardWhenFocused
                  ? "Keyboard input is sent to the C64 (click to turn off)"
                  : "Keyboard input stays on the Mac (click to send it to the C64)")
        }

        ToolbarItem(id: "viewer.onScreenKeyboard") {
            if let showOnScreenKeyboard {
                Toggle(isOn: showOnScreenKeyboard) {
                    Label("On-Screen Keyboard", systemImage: "keyboard.badge.ellipsis")
                }
                .help("Show the on-screen C64 keyboard")
            }
        }

        JoystickToolbarControls(input: session.input.settings)

        // Explicit Text labels retain the selected value on macOS 27.
        // The inline Picker inside each menu still provides checked choices.
        ToolbarItem(id: "viewer.scaling") {
            Menu {
                Picker("Scaling", selection: displayBinding(\.scalingMode)) {
                    ForEach(ScalingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(display.scalingMode.rawValue)
            }
            .labelStyle(.titleOnly)
            .accessibilityLabel("Scaling")
            .help("Video scaling for \(session.device.name)")
        }

        ToolbarItem(id: "viewer.filter") {
            Menu {
                Picker("Filter", selection: displayBinding(\.filterMode)) {
                    ForEach(FilterMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(display.filterMode.rawValue)
            }
            .labelStyle(.titleOnly)
            .accessibilityLabel("Filter")
            .help("Video filter for \(session.device.name)")
        }

        ToolbarItem(id: "viewer.input") {
            Menu {
                Picker("Input", selection: displayBinding(\.tubeInput)) {
                    ForEach(TubeInput.allCases) { input in
                        Text(input.rawValue).tag(input)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(display.tubeInput.rawValue)
            }
            .labelStyle(.titleOnly)
            .accessibilityLabel("Input")
            .help(isCRTFilter
                  ? "CRT input signal for \(session.device.name)"
                  : "CRT input signal — only applies to the CRT filters")
            .disabled(!isCRTFilter)
        }

        ToolbarItem(id: "viewer.screen") {
            Menu {
                Picker("Screen", selection: displayBinding(\.crtScreenColor)) {
                    ForEach(CRTScreenColor.allCases) { color in
                        Text(color.rawValue).tag(color)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(display.crtScreenColor.rawValue)
            }
            .labelStyle(.titleOnly)
            .accessibilityLabel("Screen")
            .help(isCRTFilter
                  ? "CRT screen phosphor for \(session.device.name)"
                  : "Screen color — only applies to the CRT filters")
            .disabled(!isCRTFilter)
        }

        ToolbarItem(id: "viewer.dirtyGlass") {
            Toggle(isOn: displayBinding(\.crtDirtyGlass)) {
                Label("Dirty Glass", systemImage: "aqi.medium")
            }
            .help(isCRTFilter
                  ? "Dirty glass on \(session.device.name)"
                  : "Dirty glass — only applies to the CRT filters")
            .disabled(!isCRTFilter)
        }

    }

    @ToolbarContentBuilder
    private var libraryControls: some ToolbarContent {
        ToolbarItem(id: "viewer.pictureControls") {
            if isCRTFilter {
                Button {
                    PictureControlsPanelController.show(display: display)
                } label: {
                    Label(
                        "Picture Controls",
                        systemImage: "slider.horizontal.3"
                    )
                }
                .help("Picture controls for \(session.device.name)")
            }
        }

        ToolbarItem(id: "viewer.screenshot") {
            Button {
                session.saveScreenshot()
            } label: {
                Label("Save Screenshot", systemImage: "camera")
            }
            .help("Screenshot \(session.device.name)")
            .disabled(!session.isConnected)
        }

        ToolbarItem(id: "viewer.recording") {
            Button {
                session.toggleRecording()
            } label: {
                Label(
                    session.isRecording ? "Stop Recording" : "Record Movie",
                    systemImage: session.isRecording ? "stop.circle.fill" : "record.circle"
                )
            }
            .help("Record source video and audio from \(session.device.name)")
            .disabled(!session.isConnected)
        }

        ToolbarItem(id: "viewer.assembly64") {
            Button {
                Stream64ToolWindows.showAssembly64()
            } label: {
                Label("Assembly64", systemImage: "books.vertical")
            }
            .help("Search the Assembly64 online library and load programs")
        }

        ToolbarItem(id: "viewer.hvsc") {
            Button {
                Stream64ToolWindows.showHVSC()
            } label: {
                Label("HVSC Browser", systemImage: "music.note.list")
            }
            .help("Browse your local High Voltage SID Collection and play SIDs")
        }

        ToolbarItem(id: "viewer.sidStation") {
            Button {
                Stream64ToolWindows.showSIDRadio()
            } label: {
                Label("SID Station", systemImage: "dot.radiowaves.left.and.right")
            }
            .help("Play a continuous SID recommendation station")
        }

        ToolbarItem(id: "viewer.fileManager") {
            Button {
                Stream64ToolWindows.showFileManager()
            } label: {
                Label("File Manager", systemImage: "rectangle.split.2x1")
            }
            .help("Browse and transfer files between this Mac and the Ultimate")
        }

        ToolbarItem(id: "viewer.driveBay") {
            Button {
                DriveBayWindowController.show(session: session)
            } label: {
                Label("Drive Bay", systemImage: "externaldrive")
            }
            .help("Drive Bay for \(session.device.name)")
            .disabled(!session.isConnected)
        }

    }

    @ToolbarContentBuilder
    private var toolControls: some ToolbarContent {
        ToolbarItem(id: "viewer.ultimateConfig") {
            Button {
                UltimateConfigWindowController.show(session: session)
            } label: {
                Label("Ultimate Config", systemImage: "gearshape.2")
            }
            .help("Flash config for \(session.device.name)")
            .disabled(!session.isConnected)
        }

        ToolbarItem(id: "viewer.memoryConsole") {
            Button {
                MemoryConsoleWindowController.show(session: session)
            } label: {
                Label("Memory Console", systemImage: "memorychip")
            }
            .help("Memory Console for \(session.device.name)")
            .disabled(!session.isConnected)
        }

        ToolbarItem(id: "viewer.debugTrace") {
            if session.supportsDebugFeatures {
                Button {
                    DebugTraceWindowController.show(session: session)
                } label: {
                    Label("Debug Trace", systemImage: "waveform.path.ecg")
                }
                .help("Debug Trace for \(session.device.name)")
                .disabled(!session.isConnected)

            }
        }

        ToolbarItem(id: "viewer.visualizations") {
            SIDVisualizationsMenu(session: session)
                .help("SID visualizations for \(session.device.name)")
                .disabled(!session.isConnected)
        }

        ToolbarItem(id: "viewer.fullScreen") {
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Enter full screen (Escape or ⌃⌘F to exit)")
        }

    }
}

/// Joystick toolbar controls observe `InputSettings` on their own so
/// capability/toggle updates don't rebuild the live `VideoView` host.
private struct JoystickToolbarControls: ToolbarContent {
    @ObservedObject var input: InputSettings

    var body: some ToolbarContent {
        ToolbarItem(id: "viewer.joystickEnabled") {
            Toggle(isOn: $input.joystickEnabled) {
                Label(
                    input.joystickEnabled
                        ? "Joystick Input" : "Keyboard Input",
                    systemImage: "gamecontroller")
            }
            .disabled(input.capability != .supported)
            .help(
                "F10 toggles virtual joystick input; fire key is configurable "
                    + "in Settings → Input")
        }
        ToolbarItem(id: "viewer.joystickPort") {
            Menu {
                Picker("Port", selection: $input.joystickPort) {
                    Text("Joy 1").tag(1)
                    Text("Joy 2").tag(2)
                }
                .pickerStyle(.inline)
            } label: {
                Text("Joy \(input.joystickPort)")
            }
            .labelStyle(.titleOnly)
            .accessibilityLabel("Port")
            .help("Virtual joystick port (F11 switches)")
        }
    }
}

/// Releases held joystick/keyboard state when joystick preferences change,
/// without observing `InputSettings` on the video host view.
private struct JoystickInputSideEffects: View {
    let session: DeviceSession
    @ObservedObject private var input: InputSettings

    init(session: DeviceSession) {
        self.session = session
        self.input = session.input.settings
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: input.joystickEnabled) {
                session.input.releaseAll()
            }
            .onChange(of: input.joystickPort) {
                session.input.releaseAll()
            }
            .onChange(of: input.joystickFireKey) {
                session.input.releaseAll()
            }
    }
}

/// Shown while a failed startup or lost connection is waiting to retry.
private struct ConnectionRetryStatus: View {
    @ObservedObject var session: DeviceSession
    var body: some View {
        if session.isReconnecting {
            Text("Retrying automatically…").font(.caption).foregroundStyle(.secondary)
            Button("Cancel Reconnection") {
                Task { await session.disconnect(stopRemoteStreams: false) }
            }
        }
    }
}
