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
    @EnvironmentObject var settings: AppSettings
    /// Host view's power-off path (shows the confirmation dialog when the
    /// preference asks for it).
    let requestPowerOff: () -> Void

    init(session: DeviceSession, requestPowerOff: @escaping () -> Void) {
        self.session = session
        self.display = session.display
        self.requestPowerOff = requestPowerOff
    }

    /// Snapshot binding into the display settings: writes go through,
    /// reads don't subscribe the menu to updates.
    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<DisplaySettings, T>) -> Binding<T> {
        Binding(get: { display[keyPath: keyPath] },
                set: { display[keyPath: keyPath] = $0 })
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

        Button("Menu Button", systemImage: "filemenu.and.selection") {
            Task { await session.menuButton() }
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

        Menu("Palette", systemImage: "paintpalette") {
            Picker("Palette", selection: bind(\.palette)) {
                ForEach(PaletteChoice.allCases) { palette in
                    Text(palette.rawValue).tag(palette)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Menu("Monitor Bezel", systemImage: "tv") {
            Toggle("Show Bezel", isOn: bind(\.showBezel))
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

        Divider()

        Toggle("Capture Keyboard", isOn: $settings.captureKeyboardWhenFocused)
    }

    private var isCRTFilter: Bool {
        display.filterMode == .crt || display.filterMode == .crtTube
    }
}
