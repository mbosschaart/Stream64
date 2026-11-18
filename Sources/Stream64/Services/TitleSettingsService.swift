import Foundation

enum TitleSettingsService {
    /// Validate the complete profile before the first mutation. Runtime-only
    /// writes are checked by readback and restored if a later setting fails.
    static func apply(_ profile: TitleSettingsProfile, api: UltimateAPIClient) async throws {
        _ = try TitleSettingsProfile(data: profile.data)
        var changes: [(category: String, key: String, value: String, previous: String)] = []
        for category in profile.values.keys.sorted() {
            let items = try await api.fetchConfigItems(category: category)
            for key in profile.values[category]!.keys.sorted() {
                let value = profile.values[category]![key]!
                guard let item = items.first(where: { $0.key == key }) else {
                    throw FileSystemError.invalidResponse("Unknown title setting: \(category) / \(key)")
                }
                if !item.options.isEmpty && !item.options.contains(where: { $0.trimmingCharacters(in: .whitespaces) == value }) {
                    throw FileSystemError.invalidResponse("Invalid choice for \(key): \(value)")
                }
                if let min = item.minimum, let max = item.maximum {
                    guard let number = Int(value), (min...max).contains(number) else {
                        throw FileSystemError.invalidResponse("\(key) must be \(min)…\(max)")
                    }
                }
                let canonical = item.options.first { $0.trimmingCharacters(in: .whitespaces) == value } ?? value
                if canonical != item.value { changes.append((category, key, canonical, item.value)) }
            }
        }
        var attempted: [(category: String, key: String, value: String, previous: String)] = []
        do {
            for change in changes {
                try Task.checkCancellation()
                attempted.append(change)
                try await api.setConfigItem(category: change.category, item: change.key, value: change.value)
                let items = try await api.fetchConfigItems(category: change.category)
                guard items.first(where: { $0.key == change.key })?.value == change.value else {
                    throw FileSystemError.invalidResponse("Title setting did not persist: \(change.key)")
                }
            }
        } catch {
            var failures: [String] = []
            // An independent task allows restoration after caller cancellation.
            let restore = Task {
                for change in attempted.reversed() {
                    do {
                        try await api.setConfigItem(category: change.category, item: change.key, value: change.previous)
                        let items = try await api.fetchConfigItems(category: change.category)
                        if items.first(where: { $0.key == change.key })?.value != change.previous { failures.append(change.key) }
                    } catch { failures.append(change.key) }
                }
                return failures
            }
            let unrestored = await restore.value
            if !unrestored.isEmpty {
                throw FileSystemError.invalidResponse("\(error.localizedDescription). Could not restore: \(unrestored.joined(separator: ", "))")
            }
            throw error
        }
    }
}

struct TitleProfileFileStore {
    let devices: [UltimateDevice]

    func provider(_ endpoint: FileEndpoint) throws -> any FileSystemProvider {
        switch endpoint {
        case .local: return LocalFileSystemProvider()
        case .ultimate(let id):
            guard let device = devices.first(where: { $0.id == id }) else { throw FileSystemError.notConnected }
            return UltimateFileSystemProvider(device: device)
        }
    }

    func load(for item: FilesystemItem) async throws -> TitleSettingsProfile? {
        let path = item.fileExtension == "cfg" ? item.path : TitleSettingsProfile.companionPath(for: item.path)
        let provider = try provider(item.endpoint)
        guard let found = try await provider.item(path) else { return nil }
        guard !found.isDirectory, (found.size ?? Int64.max) <= TitleSettingsProfile.maximumBytes else {
            throw FileSystemError.invalidResponse("Title settings exceed 64 KiB")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try await provider.download(path, to: url) { _, _ in }
        return try TitleSettingsProfile(data: Data(contentsOf: url))
    }

    func save(_ profile: TitleSettingsProfile, for item: FilesystemItem) async throws {
        let data = profile.data
        _ = try TitleSettingsProfile(data: data)
        let path = item.fileExtension == "cfg" ? item.path : TitleSettingsProfile.companionPath(for: item.path)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cfg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        let coordinator = FileOperationCoordinator(deviceResolver: { id in devices.first { $0.id == id } })
        let job = TransferJob(operation: .copy(
            source: .init(endpoint: .local, path: ManagedPath(temporary.path), isDirectory: false, size: Int64(data.count)),
            destination: .init(endpoint: item.endpoint, path: path, isDirectory: false, size: nil)), conflictPolicy: .replace)
        try await coordinator.process(job) { _, _ in }
        guard try await load(for: item) == profile else { throw FileSystemError.invalidResponse("Saved title settings did not verify") }
    }
}
