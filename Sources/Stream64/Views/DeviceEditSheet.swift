import SwiftUI

/// Sheet for adding a new device or editing an existing one,
/// with a built-in connection test.
struct DeviceEditSheet: View {
    enum Mode {
        case add
        case edit(UltimateDevice)

        var title: String {
            switch self {
            case .add: return "Add Device"
            case .edit: return "Edit Device"
            }
        }
    }

    let mode: Mode
    let onSave: (UltimateDevice) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var deviceStore: DeviceStore
    @State private var device: UltimateDevice
    @State private var testState: TestState = .idle
    @State private var ftpTestState: TestState = .idle
    @StateObject private var discovery = DeviceDiscoveryService()
    @State private var connectionTestTask: Task<Void, Never>?

    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    init(mode: Mode, suggested: UltimateDevice? = nil, onSave: @escaping (UltimateDevice) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .add:
            _device = State(initialValue: suggested ?? UltimateDevice.makeDefault())
        case .edit(let existing):
            _device = State(initialValue: existing)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isAdding {
                    discoverySection
                }

                Section(isAdding ? "Manual Configuration" : "Device") {
                    TextField("Name", text: $device.name, prompt: Text("Living Room U64"))
                    TextField("Address", text: $device.host, prompt: Text("u64.local or 192.168.1.64"))
                    TextField("API Port", value: $device.apiPort, format: .number.grouping(.never))
                    SecureField("Password", text: $device.password, prompt: Text("Optional"))
                }

                Section {
                    TextField("Video Port (local)", value: $device.videoPort, format: .number.grouping(.never))
                    TextField("Audio Port (local)", value: $device.audioPort, format: .number.grouping(.never))
                    TextField("Debug Port (local)", value: $device.debugPort, format: .number.grouping(.never))
                    Toggle("Connect automatically when selected", isOn: $device.autoConnect)
                } header: {
                    Text("Streaming")
                } footer: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Each device needs its own local ports — two devices cannot stream to the same port at once.")
                            .foregroundStyle(.secondary)
                        if let portValidationIssue {
                            Text(portValidationIssue)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    TextField(
                        "FTP Port",
                        value: Binding(
                            get: { device.effectiveFTPPort },
                            set: { device.ftpPort = $0 == 21 ? nil : $0 }),
                        format: .number.grouping(.never))
                    TextField(
                        "FTP Username",
                        text: Binding(
                            get: { device.ftpUsername ?? "" },
                            set: { device.ftpUsername = $0.isEmpty ? nil : $0 }),
                        prompt: Text(device.password.isEmpty ? "anonymous" : "admin"))
                    HStack {
                        Button("Test FTP") { testFTPConnection() }
                            .disabled(
                                portValidationIssue != nil
                                || ftpTestState == .testing)
                        switch ftpTestState {
                        case .idle: EmptyView()
                        case .testing: ProgressView().controlSize(.small)
                        case .success(let text):
                            Label(text, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let text):
                            Label(text, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                } header: {
                    Text("FTP File Service")
                } footer: {
                    Text(
                        "FTP must be enabled on the Ultimate. It uses the "
                            + "Network Password above and is unencrypted on "
                            + "your local network."
                    )
                }

                Section("Notes") {
                    TextField("Notes", text: $device.notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    HStack {
                        Button("Test Connection") {
                            testConnection()
                        }
                        .disabled(
                            device.host.isEmpty
                            || portValidationIssue != nil
                            || testState == .testing)

                        switch testState {
                        case .idle:
                            EmptyView()
                        case .testing:
                            ProgressView()
                                .controlSize(.small)
                        case .success(let info):
                            Label(info, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .lineLimit(1)
                        case .failure(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveButtonTitle) {
                    onSave(device)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    device.name.isEmpty
                    || device.host.isEmpty
                    || portValidationIssue != nil)
            }
            .padding()
        }
        .frame(width: 520, height: isAdding ? 680 : 520)
        .navigationTitle(mode.title)
        .onChange(of: device.host) { resetConnectionTest() }
        .onChange(of: device.apiPort) { resetConnectionTest() }
        .onChange(of: device.password) { resetConnectionTest() }
        .task {
            if isAdding {
                discovery.start()
            }
        }
        .onDisappear {
            discovery.cancel()
            connectionTestTask?.cancel()
        }
    }

    private var portValidationIssue: String? {
        device.portValidationIssue(among: deviceStore.devices)
    }

    @ViewBuilder
    private var discoverySection: some View {
        Section {
            if discovery.isScanning {
                ProgressView(
                    value: Double(discovery.scannedHostCount),
                    total: Double(max(discovery.totalHostCount, 1))
                )
                Text(
                    "Scanning \(discovery.scannedHostCount) of "
                        + "\(discovery.totalHostCount) local addresses…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(discovery.results) { result in
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.suggestedName)
                            .fontWeight(.medium)
                        Text(
                            result.detail.isEmpty
                                ? result.host
                                : "\(result.host) · \(result.detail)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer()
                    if isConfigured(result) {
                        Text("Already Added")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Use") {
                            useDiscoveredDevice(result)
                        }
                    }
                }
            }

            if !discovery.isScanning && discovery.results.isEmpty {
                ContentUnavailableView(
                    "No Ultimates Found",
                    systemImage: "network.slash",
                    description: Text(
                        "Check that this Mac and the Ultimate are on the "
                            + "same local network, or enter its address below."
                    )
                )
            }

            HStack {
                Button(discovery.isScanning ? "Stop Scan" : "Scan Again") {
                    if discovery.isScanning {
                        discovery.cancel()
                    } else {
                        discovery.start()
                    }
                }
                Spacer()
                Text("Manual entry is always available below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Automatic Discovery")
        } footer: {
            Text(
                "Stream64 checks a bounded set of addresses on active local "
                    + "Ethernet and Wi-Fi networks. VPN ranges are not scanned."
            )
        }
    }

    private var saveButtonTitle: String {
        switch mode {
        case .add: return "Add"
        case .edit: return "Save"
        }
    }

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    private func isConfigured(
        _ result: DeviceDiscoveryService.DiscoveredDevice
    ) -> Bool {
        deviceStore.devices.contains {
            let sameHardware: Bool
            if let discoveredID = result.uniqueID,
               let configuredID = $0.ultimateUniqueID {
                sameHardware = configuredID.caseInsensitiveCompare(
                    discoveredID
                ) == .orderedSame
            } else {
                sameHardware = false
            }
            let sameAddress = $0.host.caseInsensitiveCompare(
                result.host
            ) == .orderedSame
            return sameHardware || sameAddress
        }
    }

    private func useDiscoveredDevice(
        _ result: DeviceDiscoveryService.DiscoveredDevice
    ) {
        device = discovery.suggestedDevice(
            for: result, avoiding: deviceStore.devices)
        testState = .idle
    }

    private func testConnection() {
        connectionTestTask?.cancel()
        testState = .testing
        let client = UltimateAPIClient(device: device)
        connectionTestTask = Task {
            do {
                let info = try await client.fetchInfo()
                guard !Task.isCancelled else { return }
                let description = [info.product, info.firmwareVersion]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                testState = .success(description.isEmpty ? "Connected" : description)
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failure(error.localizedDescription)
            }
            connectionTestTask = nil
        }
    }

    private func testFTPConnection() {
        ftpTestState = .testing
        let candidate = device
        Task {
            do {
                try await UltimateFTPClient(device: candidate).testConnection()
                ftpTestState = .success("Connected")
            } catch {
                ftpTestState = .failure(error.localizedDescription)
            }
        }
    }

    private func resetConnectionTest() {
        connectionTestTask?.cancel()
        connectionTestTask = nil
        testState = .idle
    }
}
