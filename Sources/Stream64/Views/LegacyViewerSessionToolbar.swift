import SwiftUI

/// Pre-0.133 grouped toolbar for macOS 14/15. Keep this compatibility path
/// separate: the individual native item layout used on macOS 26+ can leave
/// the viewer toolbar largely empty on Sequoia. This preserves the original
/// picker presentation, grouping and overflow behaviour on those older systems.
/// When adding viewer actions, update both this and ViewerSessionToolbar.
struct LegacyViewerSessionToolbar: ToolbarContent {
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
        ToolbarItemGroup {
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

            Divider()

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

            Button {
                Task { await session.reset() }
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Reset \(session.device.name)")
            .disabled(!session.isConnected)

            Button {
                Task { await session.reboot() }
            } label: {
                Label("Reboot", systemImage: "power.circle")
            }
            .help("Reboot \(session.device.name)")
            .disabled(!session.isConnected)

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

            Button {
                session.openTelnetMonitor()
            } label: {
                Label("Ultimate Menu", systemImage: "terminal")
            }
            .help("Open the Ultimate Menu for \(session.device.name)")
            .disabled(!session.isConnected)

            Button(action: onRequestPowerOff) {
                Label("Power Off", systemImage: "power")
            }
            .help("Power off \(session.device.name)")
            .disabled(!session.isConnected)

            Divider()

            Toggle(isOn: $settings.captureKeyboardWhenFocused) {
                Label("Capture Keyboard", systemImage: "keyboard")
            }
            .help(settings.captureKeyboardWhenFocused
                  ? "Keyboard input is sent to the C64 (click to turn off)"
                  : "Keyboard input stays on the Mac (click to send it to the C64)")

            if let showOnScreenKeyboard {
                Toggle(isOn: showOnScreenKeyboard) {
                    Label("On-Screen Keyboard", systemImage: "keyboard.badge.ellipsis")
                }
                .help("Show the on-screen C64 keyboard")
            }

            LegacyJoystickToolbarControls(input: session.input.settings)

            Divider()

            Picker("Scaling", selection: displayBinding(\.scalingMode)) {
                ForEach(ScalingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .help("Video scaling for \(session.device.name)")

            Picker("Filter", selection: displayBinding(\.filterMode)) {
                ForEach(FilterMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .help("Video filter for \(session.device.name)")

            Picker("Input", selection: displayBinding(\.tubeInput)) {
                ForEach(TubeInput.allCases) { input in
                    Text(input.rawValue).tag(input)
                }
            }
            .help(isCRTFilter
                  ? "CRT input signal for \(session.device.name)"
                  : "CRT input signal — only applies to the CRT filters")
            .disabled(!isCRTFilter)

            Picker("Screen", selection: displayBinding(\.crtScreenColor)) {
                ForEach(CRTScreenColor.allCases) { color in
                    Text(color.rawValue).tag(color)
                }
            }
            .help(isCRTFilter
                  ? "CRT screen phosphor for \(session.device.name)"
                  : "Screen color — only applies to the CRT filters")
            .disabled(!isCRTFilter)

            Toggle(isOn: displayBinding(\.crtDirtyGlass)) {
                Label("Dirty Glass", systemImage: "aqi.medium")
            }
            .help(isCRTFilter
                  ? "Dirty glass on \(session.device.name)"
                  : "Dirty glass — only applies to the CRT filters")
            .disabled(!isCRTFilter)

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

            Button {
                session.saveScreenshot()
            } label: {
                Label("Save Screenshot", systemImage: "camera")
            }
            .help("Screenshot \(session.device.name)")
            .disabled(!session.isConnected)

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

            Button {
                Stream64ToolWindows.showAssembly64()
            } label: {
                Label("Assembly64", systemImage: "books.vertical")
            }
            .help("Search the Assembly64 online library and load programs")

            Button {
                Stream64ToolWindows.showHVSC()
            } label: {
                Label("HVSC Browser", systemImage: "music.note.list")
            }
            .help("Browse your local High Voltage SID Collection and play SIDs")

            Button {
                Stream64ToolWindows.showSIDRadio()
            } label: {
                Label("SID Station", systemImage: "dot.radiowaves.left.and.right")
            }
            .help("Play a continuous SID recommendation station")

            Button {
                Stream64ToolWindows.showFileManager()
            } label: {
                Label("File Manager", systemImage: "rectangle.split.2x1")
            }
            .help("Browse and transfer files between this Mac and the Ultimate")

            Button {
                DriveBayWindowController.show(session: session)
            } label: {
                Label("Drive Bay", systemImage: "externaldrive")
            }
            .help("Drive Bay for \(session.device.name)")
            .disabled(!session.isConnected)

            Button {
                UltimateConfigWindowController.show(session: session)
            } label: {
                Label("Ultimate Config", systemImage: "gearshape.2")
            }
            .help("Flash config for \(session.device.name)")
            .disabled(!session.isConnected)

            Button {
                MemoryConsoleWindowController.show(session: session)
            } label: {
                Label("Memory Console", systemImage: "memorychip")
            }
            .help("Memory Console for \(session.device.name)")
            .disabled(!session.isConnected)

            if session.supportsDebugFeatures {
                Button {
                    DebugTraceWindowController.show(session: session)
                } label: {
                    Label("Debug Trace", systemImage: "waveform.path.ecg")
                }
                .help("Debug Trace for \(session.device.name)")
                .disabled(!session.isConnected)

            }

            Menu {
                ForEach(SIDVisualizationMode.activeModes) { mode in
                    Button {
                        SIDOscilloscopeWindowController.showNewWindow(
                            session: session, mode: mode)
                    } label: {
                        Label(mode.displayName, systemImage: mode.systemImage)
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
            } label: {
                Label("SID Visualizations", systemImage: "waveform")
            }
            .help("SID visualizations for \(session.device.name)")
            .disabled(!session.isConnected)

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
private struct LegacyJoystickToolbarControls: View {
    @ObservedObject var input: InputSettings

    var body: some View {
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

        Picker("Port", selection: $input.joystickPort) {
            Text("Joy 1").tag(1)
            Text("Joy 2").tag(2)
        }
        .help("Virtual joystick port (F11 switches)")
    }
}

