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
    /// The query currently loaded into `results`, so "Load More" can page
    /// through it — a plain increasing offset keyed to whatever the search
    /// field held at the last runSearch(), independent of edits made to the
    /// field since then.
    @State private var loadedQuery = ""
    @State private var isLoadingMore = false
    /// True once a page comes back with fewer than `pageSize` results (or
    /// empty) — the definitive end-of-results signal, since the API has no
    /// separate total count.
    @State private var hasMoreResults = false

    private static let pageSize = 200

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
        // windowResizability(.contentMinSize) sizes the window from this
        // content's *ideal* size, not from the Window scene's defaultSize.
        // Without an explicit ideal here, SwiftUI computed its own (small)
        // natural ideal from the child views' minimums and the window opened
        // at ~760x548 regardless of defaultSize(900, 640) — so the ideal
        // has to be stated explicitly to actually get a 900x640 window.
        //
        // maxWidth/maxHeight: .infinity matter just as much as the ideal
        // values above: minWidth/idealWidth alone are only a *hint* used
        // for the window-sizing negotiation — they don't force this view to
        // actually expand and fill whatever size the window ends up being.
        // Without the max, the window opened at the right size (900x640)
        // but the content inside rendered at its own narrower natural
        // width and sat centered in the leftover space — the whitespace
        // down both sides, present even before any search.
        .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity,
               minHeight: 480, idealHeight: 640, maxHeight: .infinity)
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
            // Earlier attempts to fix column sizing (Table's own min/ideal
            // auto-sizing, then a GeometryReader computing exact pixel
            // widths every render) were both treating a symptom: the real
            // problem was that VSplitView doesn't stretch its panes to fill
            // its own width (see the .frame(maxWidth: .infinity) fix below
            // and on filesPane) — this pane was rendering in a too-narrow
            // container no matter how the columns inside it were sized.
            // With that fixed, Table's own auto-sizing works fine, and it's
            // simpler and doesn't fight Table's internal scroll-position
            // state the way constantly-recomputed exact widths did (that
            // combination intermittently left Table horizontally scrolled,
            // hiding the Name column entirely).
            Table(results, selection: $selectedResult) {
                TableColumn("Name") { r in Text(r.name) }
                    .width(min: 200, ideal: 340)
                TableColumn("Group") { r in Text(r.displayGroup) }
                    .width(min: 80, ideal: 140)
                TableColumn("Year") { r in
                    Text(r.year.map { $0 == 0 ? "" : String($0) } ?? "")
                }
                .width(min: 50, ideal: 70)
            }
            .onChange(of: selectedResult) { loadEntries() }

            statusBar
        }
        // VSplitView divides height between panes but — surprisingly —
        // does *not* stretch each pane to fill its own cross-axis (width):
        // confirmed by forcing VSplitView itself to the full measured
        // width and watching each pane still render at its own narrower
        // ideal width, centered inside. Each pane has to claim the full
        // width itself.
        .frame(maxWidth: .infinity, minHeight: 220)
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
                Text("\(count) result\(count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                if isLoadingMore {
                    ProgressView().controlSize(.small)
                        .padding(.leading, 4)
                } else if hasMoreResults {
                    Button("Load More") { loadMoreResults() }
                        .controlSize(.small)
                        .padding(.leading, 4)
                }
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
        // See the matching comment on resultsPane: VSplitView doesn't
        // stretch panes across the cross-axis on its own.
        .frame(maxWidth: .infinity, minHeight: 140)
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
        hasMoreResults = false

        // AQL: name term plus optional subcategory filter, sorted by name.
        // Multi-word names must be quoted or the parser reads the second
        // word as a stray term (errorCode 463).
        let name = text.contains(" ") ? "\"\(text)\"" : text
        var query = "name:\(name) sort:name order:asc"
        if let cat = selectedCategory {
            query += " subcat:\(cat.name)"
        }
        loadedQuery = query

        Task {
            do {
                let found = try await client.search(query: query, offset: 0, limit: Self.pageSize)
                results = found
                searchState = .done(count: found.count)
                hasMoreResults = found.count == Self.pageSize
            } catch {
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    /// Fetches the next page of the currently loaded query and appends it.
    /// The offset is `results.count` — safe because results only ever grow
    /// by appending pages of this same query (a fresh runSearch() clears
    /// them first).
    private func loadMoreResults() {
        guard !isLoadingMore, hasMoreResults else { return }
        isLoadingMore = true
        let query = loadedQuery
        let offset = results.count
        Task {
            defer { isLoadingMore = false }
            do {
                let found = try await client.search(query: query, offset: offset, limit: Self.pageSize)
                results.append(contentsOf: found)
                searchState = .done(count: results.count)
                hasMoreResults = found.count == Self.pageSize
            } catch {
                // Keep the existing results visible; only the "more" attempt failed.
                loadStatus = "Load more failed: \(error.localizedDescription)"
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
