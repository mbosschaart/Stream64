import SwiftUI

/// Right-click menu with the full per-stream control set — connection,
/// machine controls, file actions, and this device's display settings.
/// Attached to the video surface in both single view and grid tiles, so
/// the menu always controls the stream under the pointer.
///
/// Also embedded in the macOS **Stream** menu bar dropdown via
/// `StreamSessionCommands` (same items, selected device).
///
/// Hosts (`ViewerPane` / `ViewerTile`) must not observe `DeviceSession`
/// on the same view that owns `.contextMenu` — session fps / presentFPS
/// publishes would rebuild the host and dismiss this menu mid-selection.
struct StreamContextMenu: View {
    /// Deliberately NOT @ObservedObject: menu items read state once when
    /// the menu opens. Observing would re-render the open menu on every
    /// session publish (fps ticks each second), which collapses submenus
    /// while the user is traversing them.
    let session: DeviceSession
    let display: DisplaySettings
    let input: InputSettings
    @EnvironmentObject var settings: AppSettings
    /// Host view's power-off path (shows the confirmation dialog when the
    /// preference asks for it).
    let requestPowerOff: () -> Void
    let requestPictureControls: () -> Void
    let monitorCaseVisible: Bool

    init(
        session: DeviceSession,
        monitorCaseVisible: Bool = false,
        requestPictureControls: @escaping () -> Void = {},
        requestPowerOff: @escaping () -> Void
    ) {
        self.session = session
        self.display = session.display
        self.input = session.input.settings
        self.monitorCaseVisible = monitorCaseVisible
        self.requestPictureControls = requestPictureControls
        self.requestPowerOff = requestPowerOff
    }

    /// Snapshot binding into the display settings: writes go through,
    /// reads don't subscribe the menu to updates.
    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<DisplaySettings, T>) -> Binding<T> {
        Binding(get: { display[keyPath: keyPath] },
                set: { display[keyPath: keyPath] = $0 })
    }

    private func inputBind<T>(
        _ keyPath: ReferenceWritableKeyPath<InputSettings, T>
    ) -> Binding<T> {
        Binding(
            get: { input[keyPath: keyPath] },
            set: { input[keyPath: keyPath] = $0 })
    }

    var body: some View {
        // Connection
        if session.isConnected {
            Button("Disconnect", systemImage: "bolt.slash") {
                Task { await session.disconnect() }
            }
            if session.isStreaming {
                Button("Stop Streaming", systemImage: "stop.circle") {
                    Task { await session.stopStreams() }
                }
            } else {
                Button("Start Streaming", systemImage: "dot.radiowaves.left.and.right") {
                    Task { await session.restartStreams() }
                }
            }
        } else {
            Button("Connect", systemImage: "bolt") {
                Task { await session.connect() }
            }
        }

        Divider()

        // Machine control
        Button("Reset C64", systemImage: "arrow.counterclockwise") {
            Task { await session.reset() }
        }
        .disabled(!session.isConnected)

        Button(session.isPaused ? "Resume" : "Pause",
               systemImage: session.isPaused ? "play.fill" : "pause.fill") {
            Task { await session.togglePause() }
        }
        .disabled(!session.isConnected)

        Menu("Power", systemImage: "power") {
            Button("Reboot Ultimate", systemImage: "power.circle") {
                Task { await session.reboot() }
            }
            .disabled(!session.isConnected)
            Button("Power Off…", systemImage: "power", role: .destructive) {
                requestPowerOff()
            }
            .disabled(!session.isConnected)
        }

        Button("Save Screenshot…", systemImage: "camera") {
            session.saveScreenshot()
        }
        .disabled(!session.isConnected)

        Button("Assembly64…", systemImage: "books.vertical") {
            Stream64ToolWindows.showAssembly64()
        }

        Button("HVSC SID Browser…", systemImage: "music.note.list") {
            Stream64ToolWindows.showHVSC()
        }

        Button("File Manager…", systemImage: "rectangle.split.2x1") {
            Stream64ToolWindows.showFileManager()
        }

        Button("Drive Bay…", systemImage: "externaldrive") {
            DriveBayWindowController.show(session: session)
        }
        .disabled(!session.isConnected)

        Button("Ultimate Config…", systemImage: "gearshape.2") {
            UltimateConfigWindowController.show(session: session)
        }
        .disabled(!session.isConnected)

        Button("Memory Console…", systemImage: "memorychip") {
            MemoryConsoleWindowController.show(session: session)
        }
        .disabled(!session.isConnected)

        if session.supportsDebugFeatures {
            Button("Debug Trace…", systemImage: "waveform.path.ecg") {
                DebugTraceWindowController.show(session: session)
            }
            .disabled(!session.isConnected)

            Button("Ultimate Menu…", systemImage: "terminal") {
                session.openTelnetMonitor()
            }
            .disabled(!session.isConnected)

        }

        // Keep visualization access visible while the asynchronous debug
        // capability probe settles. The window itself will report a trace
        // failure if this device ultimately lacks debug support.
        SIDVisualizationsMenu(session: session)
            .disabled(!session.isConnected)

        Divider()

        // Display settings — this stream only
        Menu("Scaling", systemImage: "arrow.up.left.and.arrow.down.right") {
            Picker("Scaling", selection: bind(\.scalingMode)) {
                ForEach(ScalingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Menu("Filter", systemImage: "camera.filters") {
            Picker("Filter", selection: bind(\.filterMode)) {
                ForEach(FilterMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Menu("Input Signal", systemImage: "antenna.radiowaves.left.and.right") {
            Picker("Input Signal", selection: bind(\.tubeInput)) {
                ForEach(TubeInput.allCases) { input in
                    Text(input.rawValue).tag(input)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(!isCRTFilter)

        Menu("Screen Color", systemImage: "circle.lefthalf.filled") {
            Picker("Screen Color", selection: bind(\.crtScreenColor)) {
                ForEach(CRTScreenColor.allCases) { color in
                    Text(color.rawValue).tag(color)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(!isCRTFilter)

        Toggle("Dirty Glass", systemImage: "aqi.medium",
               isOn: bind(\.crtDirtyGlass))
            .disabled(!isCRTFilter)

        Menu("Palette", systemImage: "paintpalette") {
            Picker("Palette", selection: bind(\.palette)) {
                ForEach(PaletteChoice.allCases) { palette in
                    Text(palette.rawValue).tag(palette)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Toggle("Show Frame Rate", isOn: bind(\.showFPS))

        if isCRTFilter && !monitorCaseVisible {
            Button("Picture Controls…", systemImage: "slider.horizontal.3") {
                requestPictureControls()
            }
        }

        Divider()

        Menu("Input", systemImage: "gamecontroller") {
            Toggle(
                "Capture Keyboard",
                isOn: $settings.captureKeyboardWhenFocused)
            Picker("Keymap", selection: inputBind(\.keymap)) {
                ForEach(C64KeymapChoice.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            Toggle(
                "Joystick Mode (F10)",
                isOn: inputBind(\.joystickEnabled))
                .disabled(input.capability != .supported)
            Picker("Joystick Port", selection: inputBind(\.joystickPort)) {
                Text("Port 1").tag(1)
                Text("Port 2").tag(2)
            }
            Picker(
                "Fire Key",
                selection: inputBind(\.joystickFireKey)
            ) {
                ForEach(JoystickFireKey.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            Text(input.capability.label)
            Button("Recheck Input Capability") {
                Task { await session.input.probeCapability() }
            }
        }
    }

    private var isCRTFilter: Bool {
        display.filterMode == .crt || display.filterMode == .crtTube
    }
}

/// SID visualization submenu shared by the stream context menu, menu bar,
/// and toolbar.
struct SIDVisualizationsMenu: View {
    let session: DeviceSession

    var body: some View {
        Menu("SID Visualizations", systemImage: "waveform") {
            ForEach(SIDVisualizationMode.allCases) { mode in
                Button {
                    SIDOscilloscopeWindowController.showNewWindow(
                        session: session, mode: mode)
                } label: {
                    Label(mode.rawValue, systemImage: mode.systemImage)
                }
            }
            Divider()
            Button("Open All in Grid", systemImage: "square.grid.3x3") {
                session.openAllSIDVisualizations()
            }
            Button("Close All Visualizations", systemImage: "xmark.circle") {
                session.closeAllSIDVisualizations()
            }
            .disabled(!session.hasOpenSIDWindows)
            Divider()
            Button("Save Window Layout", systemImage: "square.and.arrow.down") {
                session.saveWindowLayout()
            }
            Button("Restore Window Layout", systemImage: "square.and.arrow.up") {
                session.restoreWindowLayout()
            }
            .disabled(!session.hasSavedWindowLayout)
        }
    }
}

/// Menu bar **Stream** dropdown — same actions as the video right-click menu,
/// targeting `DeviceStore.selectedDevice` (not window focus). Focus-based
/// lookup goes nil when the full-screen viewer lives on another Space and
/// the user is back on the desktop.
struct StreamSessionCommands: Commands {
    @ObservedObject var deviceStore: DeviceStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var sessionManager: SessionManager

    var body: some Commands {
        CommandMenu("Stream") {
            if let device = deviceStore.selectedDevice {
                let session = sessionManager.session(
                    for: device, settings: settings)
                StreamContextMenu(
                    session: session,
                    requestPictureControls: {
                        PictureControlsPanelController.show(
                            display: session.display)
                    },
                    requestPowerOff: {
                        NotificationCenter.default.post(
                            name: .powerOffRequested, object: session)
                    }
                )
                .environmentObject(settings)
            } else {
                Text("No Device Selected")
                    .disabled(true)
            }
        }
    }
}
