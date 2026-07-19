import SwiftUI

/// Assembly64 library browser: search the online C64 software library and
/// load results straight onto a device. Opens as its own window.
struct Assembly64View: View {
    @EnvironmentObject var deviceStore: DeviceStore
    @EnvironmentObject var settings: AppSettings
    /// Session lookup for the target device (the selected one).
    let sessionProvider: (UltimateDevice) -> DeviceSession

    private let client = Assembly64Client()

    @State private var searchText = ""
    @State private var categories: [Assembly64Client.Category] = []
    @State private var selectedCategory: Assembly64Client.Category?
    @State private var results: [Assembly64Client.SearchResult] = []
    @State private var selectedResult: Assembly64Client.SearchResult.ID?
    @State private var entries: [Assembly64Client.FileEntry] = []
    @State private var searchState: SearchState = .idle
    @State private var entriesLoading = false
    @State private var loadStatus: String?

    enum SearchState: Equatable {
        case idle, searching, done(count: Int), failed(String)
    }

    var body: some View {
        VSplitView {
            resultsPane
            filesPane
        }
        .searchable(text: $searchText, placement: .toolbar,
                    prompt: "Search Assembly64 (e.g. turrican)")
        .onSubmit(of: .search) { runSearch() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(nil as Assembly64Client.Category?)
                    ForEach(groupedCategories, id: \.0) { group, cats in
                        Section(group) {
                            ForEach(cats) { cat in
                                Text(cat.description ?? cat.name)
                                    .tag(cat as Assembly64Client.Category?)
                            }
                        }
                    }
                }
                .frame(maxWidth: 220)
                .help("Limit the search to one library category")
            }
        }
        .navigationTitle("Assembly64")
        .frame(minWidth: 640, minHeight: 480)
        .task { await loadCategories() }
        .onChange(of: selectedCategory) { runSearch() }
    }

    // Categories grouped by their grouping name for the picker.
    private var groupedCategories: [(String, [Assembly64Client.Category])] {
        Dictionary(grouping: categories) { $0.groupingName ?? "Other" }
            .sorted { $0.key < $1.key }
    }

    // MARK: - Results pane

    private var resultsPane: some View {
        VStack(spacing: 0) {
            Table(results, selection: $selectedResult) {
                TableColumn("Name") { r in Text(r.name) }
                TableColumn("Group") { r in Text(r.displayGroup) }
                    .width(min: 80, ideal: 140)
                TableColumn("Year") { r in
                    Text(r.year.map { $0 == 0 ? "" : String($0) } ?? "")
                }
                .width(50)
            }
            .onChange(of: selectedResult) { loadEntries() }

            statusBar
        }
        .frame(minHeight: 220)
    }

    private var statusBar: some View {
        HStack {
            switch searchState {
            case .idle:
                Text("Enter a search — results load onto the selected device.")
                    .foregroundStyle(.secondary)
            case .searching:
                ProgressView().controlSize(.small)
                Text("Searching…").foregroundStyle(.secondary)
            case .done(let count):
                Text(count == 200 ? "First \(count) results" : "\(count) results")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let status = loadStatus {
                Text(status).foregroundStyle(.secondary)
            }
            if let device = deviceStore.selectedDevice {
                Label(device.name, systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .help("Files load onto this device")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Files pane

    private var filesPane: some View {
        Group {
            if selectedResult == nil {
                ContentUnavailableView {
                    Label("No Item Selected", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Select a search result to see its files.")
                }
            } else if entriesLoading {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HStack {
                        Image(systemName: icon(for: entry.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(entry.filename)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        actions(for: entry)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minHeight: 140)
    }

    @ViewBuilder
    private func actions(for entry: Assembly64Client.FileEntry) -> some View {
        switch entry.kind {
        case .prg:
            Button("Run") { load(entry, behavior: .mountOnly) }
                .disabled(deviceStore.selectedDevice == nil)
        case .disk:
            Button("Mount & Run") { load(entry, behavior: .mountAndRun) }
                .disabled(deviceStore.selectedDevice == nil)
            Button("Mount") { load(entry, behavior: .mountOnly) }
                .disabled(deviceStore.selectedDevice == nil)
        case .sid:
            Button("Play") { load(entry, behavior: .mountOnly) }
                .disabled(deviceStore.selectedDevice == nil)
        case .cartridge:
            Button("Run") { load(entry, behavior: .mountOnly) }
                .disabled(deviceStore.selectedDevice == nil)
        case .other:
            Text("Unsupported")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func icon(for kind: Assembly64Client.FileKind) -> String {
        switch kind {
        case .prg: return "doc.badge.play"
        case .disk: return "opticaldisc"
        case .sid: return "music.note"
        case .cartridge: return "memorychip"
        case .other: return "doc"
        }
    }

    // MARK: - Actions

    private func loadCategories() async {
        categories = (try? await client.categories()) ?? []
    }

    private func runSearch() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searchState = .searching
        results = []
        entries = []
        selectedResult = nil

        // AQL: name term plus optional subcategory filter, sorted by name.
        // Multi-word names must be quoted or the parser reads the second
        // word as a stray term (errorCode 463).
        let name = text.contains(" ") ? "\"\(text)\"" : text
        var query = "name:\(name) sort:name order:asc"
        if let cat = selectedCategory {
            query += " subcat:\(cat.name)"
        }

        Task {
            do {
                let found = try await client.search(query: query, offset: 0, limit: 200)
                results = found
                searchState = .done(count: found.count)
            } catch {
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    private func loadEntries() {
        guard let id = selectedResult,
              let result = results.first(where: { $0.id == id }) else {
            entries = []
            return
        }
        entriesLoading = true
        entries = []
        Task {
            defer { entriesLoading = false }
            do {
                entries = try await client.entries(itemID: result.id, categoryID: result.category)
            } catch {
                searchState = .failed("Files: \(error.localizedDescription)")
            }
        }
    }

    private func load(_ entry: Assembly64Client.FileEntry, behavior: DeviceSession.MountBehavior) {
        guard let id = selectedResult,
              let result = results.first(where: { $0.id == id }),
              let device = deviceStore.selectedDevice else { return }
        let session = sessionProvider(device)
        loadStatus = "Downloading \(entry.filename)…"
        Task {
            do {
                let data = try await client.download(
                    itemID: result.id, categoryID: result.category, fileID: entry.id)
                loadStatus = nil
                await session.loadData(data, filename: entry.filename, mountBehavior: behavior)
            } catch {
                loadStatus = "Download failed: \(error.localizedDescription)"
            }
        }
    }
}
