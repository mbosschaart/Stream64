import SwiftUI

/// Right-click menu with the full per-stream control set — connection,
/// machine controls, file actions, and this device's display settings.
/// Attached to the video surface in both single view and grid tiles, so
/// the menu always controls the stream under the pointer.
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

        if session.supportsDebugFeatures {
            Button("Debug Trace…", systemImage: "waveform.path.ecg") {
                DebugTraceWindowController.show(session: session)
            }
            .disabled(!session.isConnected)

            Button("Ultimate Menu…", systemImage: "terminal") {
                session.openTelnetMonitor()
            }
            .disabled(!session.isConnected)

            // Every mode is its own entry here — picking one always opens
            // a brand-new window already set to that mode, never
            // switches whatever an existing window happens to be
            // showing (see `SIDOscilloscopeWindowController.showNewWindow`
            // and the matching in-window context menu in
            // `SIDVisualizationMenuContent`, which behaves the same way).
            Menu("SID Visualizations", systemImage: "waveform") {
                ForEach(SIDVisualizationMode.allCases) { mode in
                    Button {
                        SIDOscilloscopeWindowController.showNewWindow(session: session, mode: mode)
                    } label: {
                        Label(mode.rawValue, systemImage: mode.systemImage)
                    }
                }
                Divider()
                Button("Open All in Grid", systemImage: "square.grid.3x3") {
                    session.openAllSIDVisualizations()
                }
                Divider()
                Button("Save Window Layout", systemImage: "square.and.arrow.down") {
                    session.saveWindowLayout()
                }
                .disabled(!session.hasOpenSIDWindows)

                Button("Restore Window Layout", systemImage: "square.and.arrow.up") {
                    session.restoreWindowLayout()
                }
                .disabled(!session.hasSavedWindowLayout)
            }
            .disabled(!session.isConnected)
        }

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

        Menu("Monitor Case", systemImage: "tv") {
            Toggle("Show Monitor Case", isOn: bind(\.showBezel))
            Picker("Style", selection: bind(\.bezelStyle)) {
                ForEach(BezelChoice.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(!display.showBezel)
            Divider()
            Toggle("Tube Reflection", isOn: bind(\.bezelReflection))
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
