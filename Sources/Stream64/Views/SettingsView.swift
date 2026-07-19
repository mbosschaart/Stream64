import SwiftUI

/// The app preferences window (⌘,) with tabs for General, Devices,
/// Video, Audio and Network.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DevicesSettingsTab()
                .tabItem { Label("Devices", systemImage: "desktopcomputer") }
            VideoSettingsTab()
                .tabItem { Label("Video", systemImage: "display") }
            AudioSettingsTab()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            NetworkSettingsTab()
                .tabItem { Label("Network", systemImage: "network") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Reconnect automatically after connection loss", isOn: $settings.reconnectAutomatically)
                Toggle("Send keyboard input to the C64 when the viewer is focused", isOn: $settings.captureKeyboardWhenFocused)
                Toggle("Ask for confirmation before destructive actions", isOn: $settings.confirmDestructiveActions)
            } footer: {
                Text("Destructive actions include power off and reboot.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Devices

struct DevicesSettingsTab: View {
    @EnvironmentObject var deviceStore: DeviceStore
    @State private var selection: UUID?
    @State private var showingAdd = false
    @State private var deviceToEdit: UltimateDevice?

    var body: some View {
        VStack(spacing: 0) {
            Table(deviceStore.devices, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Address") { device in
                    Text(device.displayAddress)
                }
                TableColumn("Video Port") { device in
                    Text(String(device.videoPort))
                }
                TableColumn("Auto-connect") { device in
                    Image(systemName: device.autoConnect ? "checkmark" : "minus")
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let device = deviceStore.devices.first(where: { $0.id == id }) {
                    Button("Edit…") { deviceToEdit = device }
                    Button("Remove", role: .destructive) { deviceStore.remove(device) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let device = deviceStore.devices.first(where: { $0.id == id }) {
                    deviceToEdit = device
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a device")

                Button {
                    if let id = selection, let device = deviceStore.devices.first(where: { $0.id == id }) {
                        deviceStore.remove(device)
                        selection = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Remove selected device")

                Button("Edit…") {
                    if let id = selection {
                        deviceToEdit = deviceStore.devices.first { $0.id == id }
                    }
                }
                .disabled(selection == nil)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(isPresented: $showingAdd) {
            DeviceEditSheet(mode: .add) { deviceStore.add($0) }
        }
        .sheet(item: $deviceToEdit) { device in
            DeviceEditSheet(mode: .edit(device)) { deviceStore.update($0) }
        }
    }
}

// MARK: - Video

struct VideoSettingsTab: View {
    @EnvironmentObject var deviceStore: DeviceStore

    var body: some View {
        if let device = deviceStore.selectedDevice {
            DeviceVideoSettings(device: device,
                                display: DisplaySettings.shared(for: device.id))
                .id(device.id)
        } else {
            ContentUnavailableView("No Device Selected",
                                   systemImage: "display",
                                   description: Text("Video settings are per device — select one in the main window."))
        }
    }
}

/// Video settings for one device. Display settings are per-device so
/// each stream keeps its own look.
private struct DeviceVideoSettings: View {
    let device: UltimateDevice
    @ObservedObject var display: DisplaySettings

    var body: some View {
        Form {
            Section {
                Picker("Scaling mode", selection: $display.scalingMode) {
                    ForEach(ScalingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Scaling")
            } footer: {
                Text("These settings apply to “\(device.name)” only.")
                    .foregroundStyle(.secondary)
            }

            Section("Rendering") {
                Picker("Filtering", selection: $display.filterMode) {
                    ForEach(FilterMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Picker("Palette", selection: $display.palette) {
                    ForEach(PaletteChoice.allCases) { palette in
                        Text(palette.rawValue).tag(palette)
                    }
                }
                Picker("CRT input signal", selection: $display.tubeInput) {
                    ForEach(TubeInput.allCases) { input in
                        Text(input.rawValue).tag(input)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Monitor Bezel") {
                Toggle("Show monitor bezel", isOn: $display.showBezel)
                Picker("Style", selection: $display.bezelStyle) {
                    ForEach(BezelChoice.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .disabled(!display.showBezel)
                Toggle("Reflect the picture on the tube mask", isOn: $display.bezelReflection)
            }

            Section("Overlay") {
                Toggle("Show frame rate", isOn: $display.showFPS)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

struct AudioSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Enable audio streaming", isOn: $settings.audioEnabled)
            }

            Section {
                HStack {
                    Text("Volume")
                    Slider(value: $settings.volume, in: 0...1)
                    Text("\(Int(settings.volume * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!settings.audioEnabled)

                HStack {
                    Text("Jitter buffer")
                    Slider(value: $settings.audioBufferMs, in: 20...200, step: 10)
                    Text("\(Int(settings.audioBufferMs)) ms")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                .disabled(!settings.audioEnabled)
            } header: {
                Text("Playback")
            } footer: {
                Text("A larger jitter buffer smooths playback on busy networks at the cost of latency. Changes apply on the next connection.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Network

struct NetworkSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Connection") {
                HStack {
                    Text("Connection timeout")
                    Slider(value: $settings.connectTimeoutSeconds, in: 1...30, step: 1)
                    Text("\(Int(settings.connectTimeoutSeconds)) s")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section {
                Picker("Stream duration", selection: $settings.streamDurationSeconds) {
                    Text("Until stopped").tag(0)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                    Text("1 hour").tag(3600)
                }
            } footer: {
                Text("The Ultimate can automatically stop streaming after a fixed duration — useful as a safety net if the viewer loses connectivity.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("This Mac's address", value: LocalNetwork.primaryIPv4Address() ?? "Unknown")
            } footer: {
                Text("Streams from the Ultimate are sent to this address. Make sure the device can reach it (same network, no firewall blocking UDP).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
