import Foundation
import Combine

/// Persists configured devices as JSON in Application Support.
@MainActor
final class DeviceStore: ObservableObject {
    @Published var devices: [UltimateDevice] = [] {
        didSet { save() }
    }
    @Published var selectedDeviceID: UUID? {
        didSet { UserDefaults.standard.set(selectedDeviceID?.uuidString, forKey: "selectedDeviceID") }
    }

    var selectedDevice: UltimateDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Stream64", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("devices.json")

        // Migrate config saved under the app's previous name (UltimateViewer).
        if !FileManager.default.fileExists(atPath: url.path) {
            let legacy = support.appendingPathComponent("UltimateViewer/devices.json")
            if FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.copyItem(at: legacy, to: url)
            }
        }
        return url
    }

    init() {
        load()
        if let saved = UserDefaults.standard.string(forKey: "selectedDeviceID"),
           let uuid = UUID(uuidString: saved),
           devices.contains(where: { $0.id == uuid }) {
            selectedDeviceID = uuid
        } else {
            selectedDeviceID = devices.first?.id
        }
    }

    func add(_ device: UltimateDevice) {
        devices.append(device)
        selectedDeviceID = device.id
    }

    func update(_ device: UltimateDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
    }

    func remove(_ device: UltimateDevice) {
        devices.removeAll { $0.id == device.id }
        if selectedDeviceID == device.id {
            selectedDeviceID = devices.first?.id
        }
    }

    /// Reorders the sidebar list (drag-to-reorder). Purely cosmetic — it
    /// doesn't touch ports, UUIDs, or any live session.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        devices.move(fromOffsets: source, toOffset: destination)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        if let decoded = try? JSONDecoder().decode([UltimateDevice].self, from: data) {
            devices = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(devices) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
