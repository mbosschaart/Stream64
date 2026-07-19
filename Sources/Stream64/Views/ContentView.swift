import SwiftUI

/// Caches one live DeviceSession per device. Held in @StateObject so the
/// cache survives both body re-evaluation AND recreation of the view struct
/// (which happens whenever any observed object publishes) — a plain `let`
/// property would silently start a second session per device, splitting the
/// UI and the streams across different session objects.
@MainActor
final class SessionManager: ObservableObject {
    private var sessions: [UUID: DeviceSession] = [:]

    func session(for device: UltimateDevice, settings: AppSettings) -> DeviceSession {
        if let existing = sessions[device.id], existing.device == device {
            return existing
        }
        let session = DeviceSession(device: device, settings: settings)
        sessions[device.id] = session
        return session
    }

    /// Audio policy: exactly one device is audible — the one on screen (or
    /// selected, in the grid). Background sessions keep streaming muted.
    func muteAll(except audibleID: UUID?) {
        for (id, session) in sessions {
            session.audioReceiver.muted = id != audibleID
        }
    }

    /// Multi Drop: load a file on every connected session at once.
    func loadFileOnAllConnected(_ url: URL) {
        for session in sessions.values where session.isConnected {
            Task { await session.loadFile(at: url) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var deviceStore: DeviceStore
    @EnvironmentObject var settings: AppSettings

    @EnvironmentObject var sessionManager: SessionManager
    @State private var showingAddDevice = false
    @State private var isFullscreen = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var arrowKeyMonitor: Any?
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
        // One audible device at a time, in every view mode. Reapply whenever
        // the mode or selection changes; sessions created later respect it
        // via the same calls in the grid/pane task handlers.
        .onChange(of: showAllScreens) { applyAudioPolicy() }
        .onChange(of: deviceStore.selectedDeviceID) { applyAudioPolicy() }
        .onAppear { applyAudioPolicy() }
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullscreen = true
            columnVisibility = .detailOnly
            installArrowKeyMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
            columnVisibility = .all
            removeArrowKeyMonitor()
        }
    }

    // MARK: - Fullscreen stream switching

    /// In fullscreen with multiple devices, ←/→ switch to the previous/next
    /// stream. The monitor intercepts the keys before the video view would
    /// forward them to the C64 as cursor keys; all other keys pass through.
    private func installArrowKeyMonitor() {
        guard arrowKeyMonitor == nil else { return }
        arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard deviceStore.devices.count > 1,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  event.keyCode == 123 || event.keyCode == 124 else {
                return event
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

    private var allScreensToggle: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Toggle(isOn: $showAllScreens) {
                Label("All Screens", systemImage: "square.grid.2x2")
            }
            .help("Show all devices side by side")
        }
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

    private let columns = [GridItem(.adaptive(minimum: 420, maximum: 900), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(deviceStore.devices) { device in
                    let session = sessionManager.session(for: device, settings: settings)
                    let isSelected = deviceStore.selectedDeviceID == device.id
                    ViewerTile(session: session,
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
                        }
                        // Muting is centralized in ContentView.applyAudioPolicy;
                        // apply here too for sessions that connect after the
                        // policy last ran.
                        .onAppear { session.audioReceiver.muted = !isSelected }
                }
            }
            .padding(12)
        }
        // No custom background: the standard window background matches the
        // sidebar and toolbar in both appearances. The tiles carry their own
        // black fill.
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("All Screens")
    }
}

/// One live device tile in the grid: video, connection state, name banner.
struct ViewerTile: View {
    @ObservedObject var session: DeviceSession
    let isSelected: Bool
    /// Control-drop: deliver the file to every connected stream ("Multi Drop").
    var multiDrop: ((URL) -> Void)?
    @EnvironmentObject var settings: AppSettings
    @State private var showPowerOffConfirmation = false
    @State private var isDropTargeted = false

    var body: some View {
        tileBody
            .contextMenu {
                StreamContextMenu(session: session) {
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

    private var tileBody: some View {
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
                        Text(String(format: "%.0f fps", session.fps))
                            .font(.caption.monospacedDigit())
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
                .strokeBorder(dropBorderColor, lineWidth: isDropTargeted || isSelected ? 2 : 1)
        )
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter {
                ViewerPane.droppableExtensions.contains($0.pathExtension.lowercased())
            }
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

    private var dropBorderColor: Color {
        if isDropTargeted { return .accentColor }
        return isSelected ? Color.accentColor : .white.opacity(0.15)
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
                Text("Unreachable")
                    .font(.caption.weight(.semibold))
                Button("Retry") { Task { await session.connect() } }
                    .controlSize(.small)
            }
            .padding(8)
        case .error(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
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
                            deviceStore.remove(device)
                        }
                    }
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
                deviceStore.update(updated)
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

struct ViewerPane: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var session: DeviceSession
    /// This device's own rendering settings — observed so toolbar pickers
    /// and the video refresh when they change.
    @ObservedObject var display: DisplaySettings
    @EnvironmentObject var settings: AppSettings
    var isFullscreen: Bool = false
    /// Control-drop: deliver the file to every connected stream ("Multi Drop").
    var multiDrop: ((URL) -> Void)?
    @State private var showPowerOffConfirmation = false
    @State private var isDropTargeted = false
    @State private var showOnScreenKeyboard = false

    init(session: DeviceSession, isFullscreen: Bool = false, multiDrop: ((URL) -> Void)? = nil) {
        self.session = session
        self.display = session.display
        self.isFullscreen = isFullscreen
        self.multiDrop = multiDrop
    }

    /// Binding into the per-device display settings for toolbar controls.
    private func displayBinding<T>(_ keyPath: ReferenceWritableKeyPath<DisplaySettings, T>) -> Binding<T> {
        Binding(get: { display[keyPath: keyPath] },
                set: { display[keyPath: keyPath] = $0 })
    }

    static let droppableExtensions: Set<String> = ["prg", "d64", "g64", "d71", "g71", "d81"]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if display.showBezel {
                    MonitorBezelView(style: display.bezelStyle, display: display, session: session) {
                        VideoView(session: session)
                    }
                    .padding(12)
                } else {
                    VideoView(session: session)
                }
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
        .contextMenu {
            StreamContextMenu(session: session) {
                if settings.confirmDestructiveActions {
                    showPowerOffConfirmation = true
                } else {
                    Task { await session.powerOff() }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter { Self.droppableExtensions.contains($0.pathExtension.lowercased()) }
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
        .toolbar { toolbarContent }
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
        .onChange(of: display.tubeInput) {
            session.applyAudioSettings()
        }
        .onChange(of: display.filterMode) {
            session.applyAudioSettings()
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
            if display.showFPS {
                VStack {
                    HStack {
                        Spacer()
                        Text(String(format: "%.1f fps", session.fps))
                            .font(.caption.monospacedDigit())
                            .padding(6)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.green)
                            .padding(8)
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
                Text(".prg runs the program · disk images mount in drive A")
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

    /// The input-signal modes only affect the CRT filters.
    private var isCRTFilter: Bool {
        display.filterMode == .crt || display.filterMode == .crtTube
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            // Connection toggle
            if session.isConnected {
                Button {
                    Task { await session.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
                .help("Disconnect")
            } else {
                Button {
                    Task { await session.connect() }
                } label: {
                    Label("Connect", systemImage: "bolt")
                }
                .help("Connect")
            }

            Divider()

            if session.isStreaming {
                Button {
                    Task { await session.stopStreams() }
                } label: {
                    Label("Stop Streaming", systemImage: "stop.circle")
                }
                .help("Stop the video/audio streams (the connection stays up)")
                .disabled(!session.isConnected)
            } else {
                Button {
                    Task { await session.restartStreams() }
                } label: {
                    Label("Start Streaming", systemImage: "dot.radiowaves.left.and.right")
                }
                .help("Ask the Ultimate to stream to this Mac")
                .disabled(!session.isConnected)
            }

            Button {
                Task { await session.reset() }
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Reset the C64")
            .disabled(!session.isConnected)

            Button {
                Task { await session.reboot() }
            } label: {
                Label("Reboot", systemImage: "power.circle")
            }
            .help("Reboot the Ultimate")
            .disabled(!session.isConnected)

            Button {
                Task { await session.togglePause() }
            } label: {
                Label(session.isPaused ? "Resume" : "Pause",
                      systemImage: session.isPaused ? "play.fill" : "pause.fill")
            }
            .help(session.isPaused ? "Resume the machine" : "Pause the machine")
            .disabled(!session.isConnected)

            Button {
                Task { await session.menuButton() }
            } label: {
                Label("Menu", systemImage: "filemenu.and.selection")
            }
            .help("Press the Ultimate menu button")
            .disabled(!session.isConnected)

            Button {
                if settings.confirmDestructiveActions {
                    showPowerOffConfirmation = true
                } else {
                    Task { await session.powerOff() }
                }
            } label: {
                Label("Power Off", systemImage: "power")
            }
            .help("Power off the machine")
            .disabled(!session.isConnected)

            Divider()

            Toggle(isOn: $settings.captureKeyboardWhenFocused) {
                Label("Capture Keyboard", systemImage: "keyboard")
            }
            .help(settings.captureKeyboardWhenFocused
                  ? "Keyboard input is sent to the C64 (click to turn off)"
                  : "Keyboard input stays on the Mac (click to send it to the C64)")

            Toggle(isOn: $showOnScreenKeyboard) {
                Label("On-Screen Keyboard", systemImage: "keyboard.badge.ellipsis")
            }
            .help("Show the on-screen C64 keyboard")

            Divider()

            Picker("Scaling", selection: displayBinding(\.scalingMode)) {
                ForEach(ScalingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .help("Video scaling mode")

            Picker("Filter", selection: displayBinding(\.filterMode)) {
                ForEach(FilterMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .help("Video rendering filter")

            Picker("Input", selection: displayBinding(\.tubeInput)) {
                ForEach(TubeInput.allCases) { input in
                    Text(input.rawValue).tag(input)
                }
            }
            .help(isCRTFilter
                  ? "CRT input signal (affects picture, and sound in RF mode)"
                  : "CRT input signal — only applies to the CRT filters")
            .disabled(!isCRTFilter)

            Toggle(isOn: displayBinding(\.showBezel)) {
                Label("Monitor Bezel", systemImage: "tv")
            }
            .help("Show a Commodore monitor bezel around the picture")

            Button {
                openWindow(id: "assembly64")
            } label: {
                Label("Assembly64", systemImage: "books.vertical")
            }
            .help("Search the Assembly64 online library and load programs")

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Enter full screen (move the pointer to the top to exit)")
        }
    }
}
