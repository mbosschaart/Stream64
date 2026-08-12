import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// Per-device Drive Bay: power, mode, mount/unmount, and blank-disk create.
struct DriveBayView: View {
    @ObservedObject var model: DriveBayViewModel

    private var isConnected: Bool { model.session.isConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Drive Bay")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .fixedSize()
                .disabled(!isConnected || model.busy)
            }

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if model.drives.isEmpty {
                ContentUnavailableView(
                    "No drives reported",
                    systemImage: "externaldrive",
                    description: Text(
                        isConnected
                            ? "Refresh after the Ultimate finishes booting."
                            : "Connect to the device first."))
            } else {
                List(model.drives) { drive in
                    DriveBayRow(drive: drive, model: model)
                }
                .listStyle(.inset)
            }

            Divider()

            GroupBox("Create blank disk on Ultimate") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("Path", text: $model.createPath)
                            .textFieldStyle(.roundedBorder)
                        Picker("Type", selection: $model.createKind) {
                            ForEach(UltimateAPIClient.BlankDiskKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityLabel("Disk type")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("Disk name (optional)", text: $model.createDiskName)
                            .textFieldStyle(.roundedBorder)
                        if model.createKind == .d64 {
                            Picker("Tracks", selection: $model.createTracks) {
                                Text("35").tag(35)
                                Text("40").tag(40)
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .accessibilityLabel("Track count")
                        }
                        Button("Create") {
                            Task { await model.createBlankDisk() }
                        }
                        .fixedSize()
                        .disabled(!isConnected || model.busy)
                    }
                    Text("Example path: /Temp/blank.d64 — then mount from Drive A/B.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 360)
        .task { await model.refresh() }
    }
}

private struct DriveBayRow: View {
    let drive: UltimateAPIClient.DriveInfo
    @ObservedObject var model: DriveBayViewModel
    @AppStorage("confirmDestructiveActions") private var confirmDestructiveActions = true
    @State private var confirmPowerOff = false
    @State private var confirmUnmount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Drive \(drive.letter.uppercased())")
                    .font(.title3.weight(.semibold))
                if let bus = drive.busID {
                    Text("IEC #\(bus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(drive.enabled ? "On" : "Off")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        drive.enabled ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15),
                        in: Capsule())
            }

            Text(mountedLabel)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            // Scroll rather than ellipsize when the row is tighter than the
            // full set of control titles (Power Off / Unmount / mode menu).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(drive.enabled ? "Power Off" : "Power On") {
                        if drive.enabled, confirmDestructiveActions {
                            confirmPowerOff = true
                        } else {
                            Task {
                                await model.setPower(
                                    drive: drive.letter, on: !drive.enabled)
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(model.busy || !model.session.isConnected)

                    Picker(
                        "Mode",
                        selection: Binding(
                            get: { drive.type ?? "1541" },
                            set: { newMode in
                                Task {
                                    await model.setMode(
                                        drive: drive.letter, mode: newMode)
                                }
                            })
                    ) {
                        Text("1541").tag("1541")
                        Text("1571").tag("1571")
                        Text("1581").tag("1581")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(model.busy || !model.session.isConnected)
                    .accessibilityLabel("Drive mode")

                    Button("Mount…") {
                        model.chooseAndMount(drive: drive.letter)
                    }
                    .fixedSize()
                    .disabled(model.busy || !model.session.isConnected)

                    Button("Unmount") {
                        if confirmDestructiveActions {
                            confirmUnmount = true
                        } else {
                            Task { await model.unmount(drive: drive.letter) }
                        }
                    }
                    .fixedSize()
                    .disabled(
                        model.busy
                            || !model.session.isConnected
                            || (drive.imageFile == nil && drive.partition == nil))
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Power off drive \(drive.letter.uppercased())?",
            isPresented: $confirmPowerOff
        ) {
            Button("Power Off", role: .destructive) {
                Task {
                    await model.setPower(drive: drive.letter, on: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The drive will go offline until powered on again.")
        }
        .confirmationDialog(
            "Unmount drive \(drive.letter.uppercased())?",
            isPresented: $confirmUnmount
        ) {
            Button("Unmount", role: .destructive) {
                Task { await model.unmount(drive: drive.letter) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The mounted disk image will be ejected from this drive.")
        }
    }

    private var mountedLabel: String {
        if let image = drive.imageFile {
            return image
        }
        if let partition = drive.partition {
            return partition
        }
        return drive.type.map { "\($0) — no image" } ?? "No image"
    }
}

@MainActor
final class DriveBayViewModel: ObservableObject {
    let session: DeviceSession
    @Published private(set) var drives: [UltimateAPIClient.DriveInfo] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var busy = false
    @Published var createPath = "/Temp/blank.d64"
    @Published var createKind: UltimateAPIClient.BlankDiskKind = .d64
    @Published var createTracks = 35
    @Published var createDiskName = ""
    private var sessionObserver: AnyCancellable?

    init(session: DeviceSession) {
        self.session = session
        sessionObserver = session.$state.sink { [weak self] state in
            guard let self else { return }
            self.objectWillChange.send()
            switch state {
            case .connected:
                Task { await self.refresh() }
            case .disconnected, .unreachable, .error:
                self.drives = []
                if !self.busy {
                    self.statusMessage = "Not connected."
                }
            case .connecting:
                break
            }
        }
    }

    func refresh() async {
        guard session.isConnected else {
            statusMessage = "Not connected."
            drives = []
            return
        }
        busy = true
        defer { busy = false }
        do {
            drives = try await session.api.fetchDrives()
            statusMessage = "Updated \(Self.timestamp())."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setPower(drive: String, on: Bool) async {
        await run {
            if on {
                try await session.api.turnDriveOn(drive: drive)
            } else {
                try await session.api.turnDriveOff(drive: drive)
            }
            statusMessage = "Drive \(drive.uppercased()) powered \(on ? "on" : "off")."
        }
    }

    func setMode(drive: String, mode: String) async {
        await run {
            try await session.api.setDriveMode(drive: drive, mode: mode)
            statusMessage = "Drive \(drive.uppercased()) → \(mode)."
        }
    }

    func unmount(drive: String) async {
        await run {
            try await session.api.unmountDisk(drive: drive)
            statusMessage = "Drive \(drive.uppercased()) unmounted."
        }
    }

    func createBlankDisk() async {
        var path = createPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            statusMessage = "Enter a path for the new image."
            return
        }
        if !path.lowercased().hasSuffix(".\(createKind.fileExtension)") {
            path += ".\(createKind.fileExtension)"
            createPath = path
        }
        await run {
            try await session.api.createBlankDisk(
                path: path,
                kind: createKind,
                tracks: createKind == .d64 ? createTracks : nil,
                diskName: createDiskName)
            statusMessage = "Created \(path)."
        }
    }

    func chooseAndMount(drive: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "d64"),
            UTType(filenameExtension: "g64"),
            UTType(filenameExtension: "d71"),
            UTType(filenameExtension: "g71"),
            UTType(filenameExtension: "d81"),
        ].compactMap { $0 }
        panel.message = "Upload and mount on drive \(drive.uppercased())"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await run {
                let data = try Data(contentsOf: url)
                try await session.api.mountDisk(
                    data: data,
                    filename: url.lastPathComponent,
                    drive: drive)
                statusMessage = "Mounted \(url.lastPathComponent) on \(drive.uppercased())."
            }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        guard session.isConnected else {
            statusMessage = "Not connected."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await work()
            drives = (try? await session.api.fetchDrives()) ?? drives
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

@MainActor
final class DriveBayWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: DriveBayWindowController] = [:]
    private let deviceID: UUID

    static func show(session: DeviceSession) {
        if let existing = windows[session.device.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = DriveBayWindowController(session: session)
        windows[session.device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(session: DeviceSession) {
        deviceID = session.device.id
        let model = DriveBayViewModel(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(session.device.name) Drive Bay"
        window.minSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: DriveBayView(model: model))
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Self.windows.removeValue(forKey: deviceID)
    }
}
