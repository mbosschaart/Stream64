import SwiftUI
import AppKit

@MainActor
final class FirmwareSettingsModel: ObservableObject {
    let api: UltimateAPIClient
    let category: String
    @Published private(set) var items: [UltimateAPIClient.ConfigItem] = []
    @Published var drafts: [String: String] = [:]
    @Published private(set) var status: String?
    @Published private(set) var busy = false

    init(api: UltimateAPIClient, category: String) { self.api = api; self.category = category }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await refresh(); status = nil }
        catch { status = error.localizedDescription }
    }

    private func refresh() async throws {
        items = try await api.fetchConfigItems(category: category)
        drafts = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.value) })
    }

    func apply(_ key: String) async {
        guard !busy, let item = items.first(where: { $0.key == key }), let value = drafts[key] else { return }
        if !item.options.isEmpty && !item.options.contains(value) {
            status = "Choose a value offered by the device."; return
        }
        if let minimum = item.minimum, let maximum = item.maximum {
            guard let number = Int(value), (minimum...maximum).contains(number) else {
                status = "Enter a number from \(minimum) to \(maximum)."; return
            }
        }
        busy = true
        defer { busy = false }
        do {
            try await api.setConfigItem(category: category, item: key, value: value)
            try await refresh()
            guard items.first(where: { $0.key == key })?.value.trimmingCharacters(in: .whitespaces) == value.trimmingCharacters(in: .whitespaces) else {
                throw FileSystemError.invalidResponse("The device did not retain \(key)")
            }
            status = "\(key) applied. Use Save to Flash to keep it after power-off."
        } catch { status = error.localizedDescription }
    }

    func saveToFlash() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await api.saveConfigCategoryToFlash(category); status = "Saved to flash." }
        catch { status = error.localizedDescription }
    }
}

struct FirmwareSettingSection: View {
    @StateObject private var model: FirmwareSettingsModel
    let title: String
    let keys: [String]?
    let footer: String?

    init(api: UltimateAPIClient, category: String, title: String? = nil, keys: [String]? = nil, footer: String? = nil) {
        _model = StateObject(wrappedValue: FirmwareSettingsModel(api: api, category: category))
        self.title = title ?? category; self.keys = keys; self.footer = footer
    }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.items.filter { keys == nil || keys!.contains($0.key) }.sorted {
                    func rank(_ key: String) -> Int { key == "Vol Master" ? 0 : (key.hasPrefix("Vol ") ? 1 : 2) }
                    let a = rank($0.key), b = rank($1.key)
                    return a == b ? $0.key < $1.key : a < b
                }, id: \.key) { item in
                    HStack {
                        Text(item.key).frame(minWidth: 155, alignment: .leading)
                        if item.options.isEmpty {
                            TextField(item.key, text: Binding(get: { model.drafts[item.key] ?? item.value }, set: { model.drafts[item.key] = $0 }))
                                .textFieldStyle(.roundedBorder)
                            if let min = item.minimum, let max = item.maximum {
                                Text("\(min)…\(max)").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Picker(item.key, selection: Binding(get: { model.drafts[item.key] ?? item.value }, set: { model.drafts[item.key] = $0 })) {
                                ForEach(item.options, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        }
                        Button("Apply") { Task { await model.apply(item.key) } }
                            .disabled(model.busy || model.drafts[item.key] == item.value)
                    }
                }
                if let footer { Text(footer).font(.caption).foregroundStyle(.secondary) }
                if let status = model.status { Text(status).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Refresh") { Task { await model.load() } }
                    Spacer()
                    Button("Save to Flash") { Task { await model.saveToFlash() } }
                        .disabled(model.items.isEmpty)
                }.disabled(model.busy)
            }.padding(6)
        }.task { await model.load() }
    }
}

struct FirmwareControlsView: View {
    let session: DeviceSession
    var body: some View {
        VStack {
            TabView {
                ScrollView {
                    FirmwareSettingSection(api: session.api, category: "Audio Mixer", title: "Device Audio Mixer",
                        footer: "These levels affect the C64's outputs. Stream64's local playback volume remains separate.").padding()
                }.tabItem { Text("Audio") }
                ScrollView {
                    FirmwareSettingSection(api: session.api, category: "U64 Specific Settings", title: "Mouse",
                        keys: ["Mouse Mode", "Mouse Sensitivity", "Mouse Acceleration", "Mouse Wheel Sensitivity", "Mouse Wheel Direction", "Menu Mouse Navigation"]).padding()
                }.tabItem { Text("Mouse") }
                ScrollView {
                    FirmwareSettingSection(api: session.api, category: "SoftIEC Drive Settings", title: "Software IEC & Diagnostics",
                        footer: "UCI Only keeps the command interface available. Disabled switches the drive off completely. Operation logging may generate large logs.").padding()
                }.tabItem { Text("Software IEC") }
                ScrollView {
                    VStack {
                        FirmwareSettingSection(api: session.api, category: "U64 Specific Settings", title: "Power & Wake",
                            keys: ["Power On After Power Loss", "Wake On Wi-Fi"],
                            footer: "Wake requires an associated Wi-Fi connection. Wired Ethernet cannot wake the machine.")
                        if let mac = DeviceNetworkIdentity.wifiMAC(for: session.device.id) {
                            LabeledContent("Remembered Wi-Fi MAC", value: mac).textSelection(.enabled)
                        }
                    }.padding()
                }.tabItem { Text("Power & Wake") }
            }
            Button("Open Firmware Menu for Tape / Cartridge / Log Actions…") { session.openTelnetMonitor() }
        }.padding(12).frame(minWidth: 660, minHeight: 500)
    }
}

@MainActor
final class FirmwareControlsWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: FirmwareControlsWindowController] = [:]
    private let deviceID: UUID
    private let tracker: WorkspaceWindowTracker

    static func show(session: DeviceSession, frame: NSRect? = nil) {
        let controller = windows[session.device.id] ?? FirmwareControlsWindowController(session: session)
        windows[session.device.id] = controller
        if let frame { controller.window?.setFrame(frame, display: false) }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func captureOpenWindows() -> [WorkspaceWindowEntry] {
        windows.values.compactMap { controller in
            controller.window.map { WorkspaceRestorer.entry(kind: .firmwareControls, window: $0, deviceID: controller.deviceID) }
        }
    }

    private init(session: DeviceSession) {
        deviceID = session.device.id
        tracker = WorkspaceWindowTracker(kind: .firmwareControls, deviceID: deviceID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(session.device.name) Device Controls"
        window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: FirmwareControlsView(session: session))
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
        tracker.attach(to: window)
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { tracker.noteClosed(); Self.windows.removeValue(forKey: deviceID) }
}
