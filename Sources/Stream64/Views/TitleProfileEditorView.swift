import SwiftUI

struct TitleProfileEditorView: View {
    let item: FilesystemItem
    let devices: [UltimateDevice]
    let target: UltimateAPIClient?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var status: String?
    @State private var busy = false
    @State private var categories: [String] = []
    @State private var category = "Audio Mixer"
    @State private var embeddedName: String?

    private var fileStore: TitleProfileFileStore { .init(devices: devices) }
    private var profilePath: String {
        item.fileExtension == "cfg" ? item.path.rawValue : TitleSettingsProfile.companionPath(for: item.path).rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Title Settings — \(item.name)").font(.headline)
            if let embeddedName { LabeledContent("PC64 filename", value: embeddedName) }
            Text(profilePath).font(.caption.monospaced()).textSelection(.enabled)
            HStack {
                Picker("Capture category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                Button("Add Current Values") { Task { await capture() } }
                    .disabled(target == nil || busy || categories.isEmpty)
            }
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .border(.secondary.opacity(0.3))
                .disabled(busy)
            Text("Save creates a companion .cfg file. Stream64 validates and applies it when launching this title from Commander or a local drop. Apply Now changes the selected C64's runtime settings without saving to flash.")
                .font(.caption).foregroundStyle(.secondary)
            if let status { Text(status).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Apply Now to \(target?.device.name ?? "C64")") { Task { await apply() } }
                    .disabled(target == nil || busy)
                Button("Save Settings") { Task { await save() } }.disabled(busy)
            }
        }.padding(18).frame(minWidth: 740, minHeight: 520)
        .task { await load() }
        .interactiveDismissDisabled(busy)
    }

    private func load() async {
        busy = true; defer { busy = false }
        do {
            if let profile = try await fileStore.load(for: item) { text = String(decoding: profile.data, as: UTF8.self) }
            else { text = "; Settings for \(item.name)\n" }
            if let target {
                categories = try await target.fetchConfigCategories()
                if !categories.contains(category) { category = categories.first ?? "" }
            }
            if ["p00", "s00", "u00", "r00"].contains(item.fileExtension), (item.size ?? Int64.max) <= 128 * 1024 {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: url) }
                try await fileStore.provider(item.endpoint).download(item.path, to: url) { _, _ in }
                embeddedName = try PC64File(data: Data(contentsOf: url), filename: item.name).name
            }
        } catch { status = error.localizedDescription }
    }

    private func capture() async {
        guard let target else { return }
        busy = true; defer { busy = false }
        do {
            var profile = try TitleSettingsProfile(data: Data(text.utf8))
            let items = try await target.fetchConfigItems(category: category)
            profile.values[category] = Dictionary(uniqueKeysWithValues: items.filter {
                !$0.key.localizedCaseInsensitiveContains("password")
            }.map { ($0.key, $0.value) })
            _ = try TitleSettingsProfile(data: profile.data)
            text = String(decoding: profile.data, as: UTF8.self)
            status = "Captured \(category). Review the items before saving."
        } catch { status = error.localizedDescription }
    }

    private func save() async {
        busy = true; defer { busy = false }
        do {
            let profile = try TitleSettingsProfile(data: Data(text.utf8))
            try await fileStore.save(profile, for: item)
            text = String(decoding: profile.data, as: UTF8.self)
            status = "Saved and verified \(profilePath)."
        } catch { status = error.localizedDescription }
    }

    private func apply() async {
        guard let target else { return }
        busy = true; defer { busy = false }
        do {
            let profile = try TitleSettingsProfile(data: Data(text.utf8))
            try await TitleSettingsService.apply(profile, api: target)
            status = "Applied and verified runtime settings on \(target.device.name)."
        } catch { status = error.localizedDescription }
    }
}
