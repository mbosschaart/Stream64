import SwiftUI
import AppKit
import Combine

/// Browse and edit Ultimate flash configuration categories over REST.
struct UltimateConfigView: View {
    @ObservedObject var model: UltimateConfigViewModel
    @AppStorage("confirmDestructiveActions") private var confirmDestructiveActions = true
    @State private var confirmSaveToFlash = false

    private var isConnected: Bool { model.session.isConnected }

    var body: some View {
        HSplitView {
            List(model.categories, id: \.self, selection: $model.selectedCategory) { category in
                Text(category)
            }
            .frame(minWidth: 200, idealWidth: 240)

            VStack(alignment: .leading, spacing: 0) {
                toolbar
                Divider()
                if model.items.isEmpty {
                    ContentUnavailableView(
                        model.selectedCategory == nil
                            ? "Select a category"
                            : "No items",
                        systemImage: "slider.horizontal.3",
                        description: Text(model.statusMessage ?? ""))
                } else {
                    Table(model.items) {
                        TableColumn("Item") { item in
                            Text(item.key)
                                .font(.body.monospaced())
                        }
                        .width(min: 160, ideal: 220)
                        TableColumn("Value") { item in
                            TextField(
                                "",
                                text: Binding(
                                    get: { model.draftValues[item.key] ?? item.value },
                                    set: { model.draftValues[item.key] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospaced())
                        }
                        TableColumn("") { item in
                            Button("Set") {
                                Task { await model.apply(itemKey: item.key) }
                            }
                            .fixedSize()
                            .disabled(model.busy || !isConnected)
                        }
                        .width(min: 52, ideal: 56)
                    }
                }
            }
            .frame(minWidth: 360)
        }
        .padding(10)
        .frame(minWidth: 720, minHeight: 420)
        .task { await model.loadCategories() }
        .confirmationDialog(
            "Save configuration to flash?",
            isPresented: $confirmSaveToFlash
        ) {
            Button("Save to Flash", role: .destructive) {
                Task { await model.saveToFlash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes the current Ultimate configuration into flash memory on the device.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(model.selectedCategory ?? "Ultimate Config")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Prefer scrolling the action cluster over ellipsizing titles.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Reload") {
                        Task { await model.reloadSelected() }
                    }
                    .fixedSize()
                    .disabled(model.busy || model.selectedCategory == nil)
                    Button("Load from Flash") {
                        Task { await model.loadFromFlash() }
                    }
                    .fixedSize()
                    .disabled(model.busy || !isConnected)
                    Button("Save to Flash") {
                        if confirmDestructiveActions {
                            confirmSaveToFlash = true
                        } else {
                            Task { await model.saveToFlash() }
                        }
                    }
                    .fixedSize()
                    .disabled(model.busy || !isConnected)
                }
            }
        }
        .padding(.bottom, 8)
    }
}

struct UltimateConfigItem: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let value: String
}

@MainActor
final class UltimateConfigViewModel: ObservableObject {
    let session: DeviceSession
    @Published private(set) var categories: [String] = []
    @Published var selectedCategory: String? {
        didSet {
            guard selectedCategory != oldValue else { return }
            Task { await reloadSelected() }
        }
    }
    @Published private(set) var items: [UltimateConfigItem] = []
    @Published var draftValues: [String: String] = [:]
    @Published private(set) var statusMessage: String?
    @Published private(set) var busy = false
    private var sessionObserver: AnyCancellable?

    init(session: DeviceSession) {
        self.session = session
        sessionObserver = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func loadCategories() async {
        guard session.isConnected else {
            statusMessage = "Not connected."
            return
        }
        busy = true
        defer { busy = false }
        do {
            categories = try await session.api.fetchConfigCategories()
            if selectedCategory == nil {
                selectedCategory = categories.first
            } else {
                await reloadSelected()
            }
            statusMessage = "\(categories.count) categories."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func reloadSelected() async {
        guard let category = selectedCategory else {
            items = []
            return
        }
        guard session.isConnected else {
            statusMessage = "Not connected."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let pairs = try await session.api.fetchConfigItems(category: category)
            items = pairs.map { UltimateConfigItem(key: $0.key, value: $0.value) }
            draftValues = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) })
            statusMessage = "\(items.count) items in \(category)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func apply(itemKey: String) async {
        guard let category = selectedCategory,
              let value = draftValues[itemKey] else { return }
        busy = true
        defer { busy = false }
        do {
            try await session.api.setConfigItem(
                category: category, item: itemKey, value: value)
            statusMessage = "Set \(itemKey)."
            await reloadSelected()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveToFlash() async {
        busy = true
        defer { busy = false }
        do {
            try await session.api.saveConfigToFlash()
            statusMessage = "Saved to flash."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadFromFlash() async {
        busy = true
        defer { busy = false }
        do {
            try await session.api.loadConfigFromFlash()
            statusMessage = "Loaded from flash."
            await loadCategories()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

@MainActor
final class UltimateConfigWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: UltimateConfigWindowController] = [:]
    private let deviceID: UUID

    static func show(session: DeviceSession) {
        if let existing = windows[session.device.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = UltimateConfigWindowController(session: session)
        windows[session.device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(session: DeviceSession) {
        deviceID = session.device.id
        let model = UltimateConfigViewModel(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(session.device.name) Config"
        window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: UltimateConfigView(model: model))
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Self.windows.removeValue(forKey: deviceID)
    }
}
