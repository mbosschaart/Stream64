import SwiftUI
import UniformTypeIdentifiers

/// The app preferences window (⌘,) with tabs for General, Devices,
/// Display, Audio, Input and Network.
struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case general, devices, display, audio, input, network
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @State private var selection: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ForEach(Tab.allCases) { tab in
                    settingsTabButton(tab)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)

            Divider()

            settingsContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selection.title)
        .frame(width: 600, height: 470)
    }

    private func settingsTabButton(_ tab: Tab) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                settingsIcon(tab)
                    .frame(width: 34, height: 27)
                Text(verbatim: tab.title)
                    .font(.caption)
            }
            .foregroundStyle(
                selection == tab ? Color.accentColor : Color.primary)
            .frame(width: 70, height: 52)
            .background(
                selection == tab
                    ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingsIcon(_ tab: Tab) -> some View {
        switch tab {
        case .general:
            Image(systemName: "gearshape")
                .font(.system(size: 25))
        case .devices:
            Image(systemName: "powerplug")
                .font(.system(size: 25))
        case .display:
            Image(systemName: "display")
                .font(.system(size: 25))
        case .audio:
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 25))
        case .input:
            Image(systemName: "gamecontroller")
                .font(.system(size: 25))
        case .network:
            Image(systemName: "network")
                .font(.system(size: 25))
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selection {
        case .general: GeneralSettingsTab()
        case .devices: DevicesSettingsTab()
        case .display: VideoSettingsTab()
        case .audio: AudioSettingsTab()
        case .input: InputSettingsTab()
        case .network: NetworkSettingsTab()
        }
    }
}

// MARK: - Input

struct InputSettingsTab: View {
    @EnvironmentObject var deviceStore: DeviceStore

    var body: some View {
        if let device = deviceStore.selectedDevice {
            DeviceInputSettings(
                device: device,
                input: InputSettings.shared(for: device.id))
                .id(device.id)
        } else {
            ContentUnavailableView(
                "No Device Selected",
                systemImage: "gamecontroller",
                description: Text(
                    "Input settings are per device—select one first."))
        }
    }
}

private struct DeviceInputSettings: View {
    let device: UltimateDevice
    @ObservedObject var input: InputSettings
    @State private var importingKeymap = false
    @State private var importError: String?

    var body: some View {
        Form {
            Section("Keyboard") {
                Picker("Input transport", selection: $input.transport) {
                    ForEach(InputTransportPreference.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                Picker("Keymap", selection: $input.keymap) {
                    ForEach(C64KeymapChoice.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                HStack {
                    Button("Import Keymap…") {
                        importingKeymap = true
                    }
                    if let name = input.customKeymapName {
                        Text(name).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Capability", value: input.capability.label)
                LabeledContent(
                    "Network services",
                    value: input.servicesReady ? "Ready" : "Not verified")
            }

            Section {
                Toggle(
                    "Use keyboard as virtual joystick",
                    isOn: $input.joystickEnabled)
                    .disabled(input.capability != .supported)
                Picker("Joystick port", selection: $input.joystickPort) {
                    Text("Port 1").tag(1)
                    Text("Port 2").tag(2)
                }
                .pickerStyle(.segmented)
                Picker(
                    "Keyboard fire button",
                    selection: $input.joystickFireKey
                ) {
                    ForEach(JoystickFireKey.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                Toggle(
                    "Enable connected game controllers",
                    isOn: $input.gameControllerEnabled)
                HStack {
                    Text("Stick deadzone")
                    Slider(value: $input.deadzone, in: 0.1...0.8)
                    Text(input.deadzone, format: .percent)
                        .monospacedDigit()
                        .frame(width: 48)
                }
                LabeledContent(
                    "Controller",
                    value: input.connectedControllerName ?? "None")
            } header: {
                Text("Virtual Joystick")
            } footer: {
                Text(
                    "F10 toggles joystick mode; F11 switches ports. "
                        + "Matrix input requires supported Ultimate firmware.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $importingKeymap,
            allowedContentTypes: [.plainText, .data]
        ) { result in
            do {
                try input.importKeymap(from: result.get())
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert(
            "Keymap Import Failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updateService: UpdateService
    @EnvironmentObject var sidFlowRecommendations: SIDFlowRecommendationStore
    @State private var psid64 = PSID64Service()
    @State private var psid64Status = ""

    var body: some View {
        Form {
            Section {
                Toggle("Reconnect automatically after connection loss", isOn: $settings.reconnectAutomatically)
                Toggle("Send keyboard input to the C64 when the viewer is focused", isOn: $settings.captureKeyboardWhenFocused)
                Toggle("Ask for confirmation before destructive actions", isOn: $settings.confirmDestructiveActions)
                Toggle("Check for updates automatically", isOn: $settings.checkForUpdatesAutomatically)
                Toggle(
                    "Visualisations auto-follow selected C64",
                    isOn: $settings.visualizationsAutoFollowSelected)
                Toggle(
                    "Keep U64 debug stream running while connected",
                    isOn: $settings.keepDebugStreamWarm)
                Toggle(
                    "Log U64 debug stream lifecycle",
                    isOn: $settings.debugLifecycleLogging)
                Toggle(
                    "Oscilloscope post-mix lowpass overlay",
                    isOn: $settings.oscilloscopePostMixLowpassOverlay)
            } footer: {
                Text(
                    "Destructive actions include power off, file deletion, "
                        + "replacement, non-atomic moves, Save to Flash, and "
                        + "Drive Bay power-off / unmount. When "
                        + "auto-follow is on, open SID and Memory Map / "
                        + "Debug Trace windows switch to the newly selected "
                        + "machine. Sound always follows selection. The warm "
                        + "debug stream applies only to hardware that supports "
                        + "it and avoids restarting it when opening SID or "
                        + "Debug Trace windows. Debug lifecycle logging writes "
                        + "diagnostic counters to the macOS unified log. The "
                        + "oscilloscope lowpass overlay shows real post-mix "
                        + "bass/kick energy for filter or digi-driven drums."
                )
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Check for Updates…") {
                    updateService.check(force: true)
                }
            } footer: {
                Text(
                    "Stable releases are downloaded from the Stream64 GitHub "
                        + "repository, checksum-verified, signature-checked, "
                        + "then installed and relaunched automatically."
                )
                    .foregroundStyle(.secondary)
            }
            sidRadioSection
            psid64Section
        }
        .formStyle(.grouped)
    }

    private var psid64Section: some View {
        let version = psid64.installedVersion()
        return Section {
            LabeledContent("Converter", value: version ?? "Not installed")
            if version != nil {
                Text(psid64.installationPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Remove PSID64", role: .destructive) {
                    do {
                        try psid64.removeInstalledTool()
                        psid64Status = "PSID64 removed."
                    } catch {
                        psid64Status = error.localizedDescription
                    }
                }
            }
            Link("PSID64 project and GPL source", destination: PSID64Service.sourceURL)
            if !psid64Status.isEmpty {
                Text(psid64Status).foregroundStyle(.secondary)
            }
        } header: {
            Text("PSID64 Playback")
        } footer: {
            Text(
                "Multi-SID PSID and RSID files are converted to PRGs with user-approved PSID64 "
                    + "to improve real-C64 compatibility. v1/v2 files use Ultimate native playback. "
                    + "PSID64 is GPL-2.0-or-later and is downloaded from its upstream release.")
                .foregroundStyle(.secondary)
        }
    }

    private var sidRadioSection: some View {
        Section {
            LabeledContent(
                "Recommendation data",
                value: sidFlowRecommendations.isInstalled ? "Installed" : "Not installed")
            if let manifest = sidFlowRecommendations.manifest {
                LabeledContent("Corpus", value: manifest.hvscVersion ?? manifest.corpusVersion)
                LabeledContent("Tracks", value: String(manifest.trackCount))
            }
            HStack {
                Button(sidFlowRecommendations.isInstalled ? "Update SIDFlow Data" : "Download SIDFlow Data") {
                    Task { await sidFlowRecommendations.downloadLatest() }
                }
                .disabled(sidFlowRecommendations.isLoading)
                if sidFlowRecommendations.isInstalled {
                    Button("Remove Data", role: .destructive) {
                        sidFlowRecommendations.removeDownloadedData()
                    }
                }
            }
            if sidFlowRecommendations.isLoading {
                ProgressView().controlSize(.small)
            }
            HStack {
                Text("Fallback song length")
                Slider(value: $settings.sidRadioFallbackDurationSeconds, in: 30...600, step: 15)
                Text("\(Int(settings.sidRadioFallbackDurationSeconds / 60)) min")
                    .monospacedDigit()
                    .frame(width: 48)
            }
            Toggle(
                "Fade out at the end of SID Station tracks",
                isOn: $settings.sidRadioFadeOutEnabled)
            Text(sidFlowRecommendations.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("SID Station")
        } footer: {
            Text(
                "Stream64 downloads only SIDFlow's verified recommendation data. "
                    + "Actual SID files are resolved from HVSC just before playback and are never cached.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Devices

struct DevicesSettingsTab: View {
    @EnvironmentObject var deviceStore: DeviceStore
    @EnvironmentObject var sessionManager: SessionManager
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
                    Button("Remove", role: .destructive) {
                        Task { await remove(device) }
                    }
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
                        Task {
                            await remove(device)
                            selection = nil
                        }
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
            DeviceEditSheet(
                mode: .add,
                suggested: .makeDefault(avoiding: deviceStore.devices)
            ) { deviceStore.add($0) }
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

    private func remove(_ device: UltimateDevice) async {
        await sessionManager.removeSession(id: device.id)
        deviceStore.remove(device)
    }
}

// MARK: - Display

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

            Section {
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
                Picker("CRT screen color", selection: $display.crtScreenColor) {
                    ForEach(CRTScreenColor.allCases) { color in
                        Text(color.rawValue).tag(color)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!isCRTFilter)
                Toggle("Years of dirt and grime on the CRT glass",
                       isOn: $display.crtDirtyGlass)
                    .disabled(!isCRTFilter)
                Toggle("Glass reflection", isOn: $display.bezelReflection)
                    .disabled(!isCRTTube)
                Picker("Phosphor pitch", selection: $display.bezelStyle) {
                    ForEach(BezelChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .disabled(!isCRTTube)
            } header: {
                Text("Rendering")
            } footer: {
                Text(
                    "Phosphor pitch matches Commodore 1702 (0.64 mm) or "
                        + "1084S (0.42 mm) shadow-mask spacing. Glass "
                        + "reflection and pitch apply in CRT Tube mode."
                )
                .foregroundStyle(.secondary)
            }

            Section("Overlay") {
                Toggle("Show frame rate", isOn: $display.showFPS)
            }
        }
        .formStyle(.grouped)
    }

    private var isCRTFilter: Bool {
        display.filterMode == .crt || display.filterMode == .crtTube
    }

    private var isCRTTube: Bool {
        display.filterMode == .crtTube
    }
}

// MARK: - Audio

struct AudioSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sessionManager: SessionManager
    @State private var outputDevices: [AudioOutputDevices.Device] = []

    var body: some View {
        Form {
            Section {
                Toggle("Enable audio streaming", isOn: $settings.audioEnabled)
            }

            Section {
                Picker("Mac speaker / headphones", selection: $settings.audioOutputDeviceUID) {
                    Text("System Default").tag(AudioOutputDevices.systemDefaultUID)
                    ForEach(outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .disabled(!settings.audioEnabled)

                if !settings.audioOutputDeviceUID.isEmpty,
                   !outputDevices.contains(where: { $0.uid == settings.audioOutputDeviceUID }) {
                    Text("The previously chosen device is unavailable; playback is using the system default until it returns or you pick another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                AirPlaySettingsControl(
                    controller: sessionManager.airPlayOutput)
            } header: {
                Text("Output")
            } footer: {
                Text("Local Stream64 playback uses the device above. AirPlay is a separate app-wide route and does not change this Mac's system output.")
                    .foregroundStyle(.secondary)
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
        .onAppear { outputDevices = AudioOutputDevices.listOutputs() }
        .onChange(of: settings.audioOutputDeviceUID) {
            sessionManager.applyAudioOutputDeviceUID(settings.audioOutputDeviceUID)
        }
    }
}

private struct AirPlaySettingsControl: View {
    @ObservedObject var controller: AirPlayOutputController

    var body: some View {
        HStack {
            AirPlayRoutePickerView(
                controller: controller,
                identifier: "audio-settings")
                .frame(width: 30, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.state.label)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(
                        isFailure ? Color.red : Color.secondary)
            }
            Spacer()
            if controller.externalOutputActive {
                Button("This Mac") {
                    controller.stopAirPlay()
                }
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = controller.state { return true }
        return false
    }

    private var statusDetail: String {
        switch controller.state {
        case .local:
            return "Use the AirPlay button to choose a receiver."
        case .preparing:
            return "Starting the temporary live-audio stream."
        case .connecting:
            return "AirPlay may take a few seconds to buffer."
        case .airPlay:
            return "All Stream64 audio is routed here with about 1–3 seconds of latency."
        case .failed(let message):
            return message
        }
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
                LabeledContent("This Mac's address",
                               value: LocalNetwork.primaryIPv4Address() ?? "Unknown")
            } footer: {
                Text("Streams from the Ultimate are sent to this address. Make sure the device can reach it (same network, no firewall blocking UDP).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
