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
    @State private var device: UltimateDevice
    @State private var testState: TestState = .idle

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
                Section("Device") {
                    TextField("Name", text: $device.name, prompt: Text("Living Room U64"))
                    TextField("Address", text: $device.host, prompt: Text("u64.local or 192.168.1.64"))
                    TextField("API Port", value: $device.apiPort, format: .number.grouping(.never))
                    SecureField("Password", text: $device.password, prompt: Text("Optional"))
                }

                Section {
                    TextField("Video Port (local)", value: $device.videoPort, format: .number.grouping(.never))
                    TextField("Audio Port (local)", value: $device.audioPort, format: .number.grouping(.never))
                    Toggle("Connect automatically when selected", isOn: $device.autoConnect)
                } header: {
                    Text("Streaming")
                } footer: {
                    Text("Each device needs its own local ports — two devices cannot stream to the same port at once.")
                        .foregroundStyle(.secondary)
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
                        .disabled(device.host.isEmpty || testState == .testing)

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
                .disabled(device.name.isEmpty || device.host.isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 520)
        .navigationTitle(mode.title)
    }

    private var saveButtonTitle: String {
        switch mode {
        case .add: return "Add"
        case .edit: return "Save"
        }
    }

    private func testConnection() {
        testState = .testing
        let client = UltimateAPIClient(device: device)
        Task {
            do {
                let info = try await client.fetchInfo()
                let description = [info.product, info.firmwareVersion]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                testState = .success(description.isEmpty ? "Connected" : description)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
