import SwiftUI
import UniformTypeIdentifiers

/// Assembly64 library browser: discovery filters, favorites, saved searches,
/// previews/history, and direct loading onto the selected Ultimate.
struct Assembly64View: View {
    enum LibraryScope: String, CaseIterable, Identifiable {
        case search = "Search"
        case favorites = "Favorites"
        case recent = "Recent"

        var id: String { rawValue }
    }

    struct ArchivePreview: Identifiable {
        let id = UUID()
        let result: Assembly64Client.SearchResult
        let data: Data
        let items: [Assembly64ArchiveInspector.Item]
    }

    @EnvironmentObject var deviceStore: DeviceStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: Assembly64LibraryStore
    /// Session lookup for the target device (the selected one).
    let sessionProvider: (UltimateDevice) -> DeviceSession

    private let client = Assembly64Client()

    @State private var scope: LibraryScope = .search
    @State private var searchText = ""
    @State private var filters = Assembly64SearchFilters()
    @State private var categories: [Assembly64Client.Category] = []
    @State private var presets: [Assembly64Client.AQLPreset] = []
    @State private var selectedCategory: Assembly64Client.Category?
    @State private var searchResults: [Assembly64Client.SearchResult] = []
    @State private var selectedResult: Assembly64Client.SearchResult.ID?
    @State private var entries: [Assembly64Client.FileEntry] = []
    @State private var itemMetadata: Assembly64Client.Metadata?
    @State private var fallbackPreview: CSDBPreviewClient.Preview?
    @State private var searchState: SearchState = .idle
    @State private var entriesLoading = false
    @State private var metadataLoading = false
    @State private var loadStatus: String?
    @State private var loadedQuery = ""
    @State private var isLoadingMore = false
    @State private var hasMoreResults = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectionTask: Task<Void, Never>?
    @State private var showingSaveSearch = false
    @State private var savedSearchName = ""
    @State private var archivePreview: ArchivePreview?
    @State private var actionTarget: DeviceActionTarget?

    private static let pageSize = 200

    enum SearchState: Equatable {
        case idle, searching, done(count: Int), failed(String)
    }

    private var displayedResults: [Assembly64Client.SearchResult] {
        switch scope {
        case .search: return searchResults
        case .favorites: return library.favoriteResults
        case .recent: return library.recentResults
        }
    }

    private var selectedItem: Assembly64Client.SearchResult? {
        guard let selectedResult else { return nil }
        return displayedResults.first { $0.id == selectedResult }
    }

    private var targetDevices: [UltimateDevice] {
        switch actionTarget {
        case .device(let id):
            return deviceStore.devices.filter { $0.id == id }
        case .allConnected:
            return deviceStore.devices.filter {
                sessionProvider($0).isConnected
            }
        case nil:
            return deviceStore.selectedDevice.map { [$0] } ?? []
        }
    }

    private var targetLabel: String {
        if case .allConnected = actionTarget {
            return "All Connected C64s (\(targetDevices.count))"
        }
        return targetDevices.first?.name ?? "No Target"
    }

    var body: some View {
        VStack(spacing: 0) {
            resultsPane
            Divider()
            filesPane
        }
        .searchable(text: $searchText, placement: .toolbar,
                    prompt: "Search Assembly64 (e.g. turrican)")
        .onSubmit(of: .search) { runSearch() }
        .toolbar { toolbarContent }
        .navigationTitle("Assembly64")
        .frame(minWidth: 900, idealWidth: 980, maxWidth: .infinity,
               minHeight: 580, idealHeight: 680, maxHeight: .infinity,
               alignment: .top)
        .task { await loadReferenceData() }
        .onAppear {
            if actionTarget == nil, let id = deviceStore.selectedDeviceID {
                actionTarget = .device(id)
            }
        }
        .onChange(of: scope) {
            clearSelection()
        }
        .alert("Save Search", isPresented: $showingSaveSearch) {
            TextField("Search name", text: $savedSearchName)
            Button("Save") { saveCurrentSearch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save the current text, category and filters.")
        }
        .sheet(item: $archivePreview) { preview in
            archiveInspector(preview)
        }
        .onDisappear {
            searchTask?.cancel()
            selectionTask?.cancel()
        }
    }

    // MARK: - Toolbar and filters

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Library", selection: $scope) {
                ForEach(LibraryScope.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
        }

        ToolbarItem {
            Picker("Target", selection: $actionTarget) {
                ForEach(deviceStore.devices) { device in
                    Text(device.name)
                        .tag(Optional(DeviceActionTarget.device(device.id)))
                }
                Divider()
                Text("All Connected C64s")
                    .tag(Optional(DeviceActionTarget.allConnected))
            }
            .frame(maxWidth: 210)
            .help("Device target for Run, Play, Mount, and Mount & Run")
        }

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
            .frame(maxWidth: 150)
            .disabled(scope != .search)
            .help("Limit search to one Assembly64 subcategory")
        }

        ToolbarItem {
            Menu {
                repositoryPicker
                fileTypePicker
                yearPicker
                ratingPicker
                latestPicker
                Divider()
                sortPicker
                orderPicker
                Divider()
                Button("Apply Filters") { runSearch() }
                Button("Clear Filters") {
                    filters = Assembly64SearchFilters()
                    runSearch()
                }
            } label: {
                Label("Filters", systemImage: filters.hasActiveFilters
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            .disabled(scope != .search)
            .help("Repository, file type, year, rating, recency and sorting")
        }

        ToolbarItem {
            Menu {
                Button("Save Current Search…", systemImage: "plus") {
                    savedSearchName = defaultSavedSearchName
                    showingSaveSearch = true
                }
                .disabled(!canSearch)

                if !library.savedSearches.isEmpty {
                    Divider()
                    ForEach(library.savedSearches) { saved in
                        Button(saved.name) { apply(saved) }
                    }
                    Divider()
                    Menu("Remove Saved Search") {
                        ForEach(library.savedSearches) { saved in
                            Button(saved.name, role: .destructive) {
                                library.removeSavedSearch(saved)
                            }
                        }
                    }
                }
            } label: {
                Label("Saved Searches", systemImage: "bookmark")
            }
        }
    }

    @ViewBuilder
    private var repositoryPicker: some View {
        Picker("Repository", selection: $filters.repository) {
            Text("Any Repository").tag("")
            ForEach(presetValues("repo"), id: \.aqlKey) { value in
                Text(value.displayName).tag(value.aqlKey)
            }
        }
    }

    @ViewBuilder
    private var fileTypePicker: some View {
        Picker("File Type", selection: $filters.fileType) {
            Text("Any File Type").tag("")
            ForEach(presetValues("type"), id: \.aqlKey) { value in
                Text(value.displayName).tag(value.aqlKey)
            }
        }
    }

    @ViewBuilder
    private var yearPicker: some View {
        Picker("Year", selection: $filters.year) {
            Text("Any Year").tag(nil as Int?)
            ForEach(presetValues("date"), id: \.aqlKey) { value in
                if let year = Int(value.aqlKey) {
                    Text(value.aqlKey).tag(year as Int?)
                }
            }
        }
    }

    @ViewBuilder
    private var ratingPicker: some View {
        Picker("Minimum Rating", selection: $filters.minimumRating) {
            Text("Any Rating").tag(nil as Int?)
            ForEach(1...10, id: \.self) { rating in
                Text("\(rating)+").tag(rating as Int?)
            }
        }
    }

    @ViewBuilder
    private var latestPicker: some View {
        Picker("Updated", selection: $filters.latest) {
            Text("Any Time").tag("")
            ForEach(presetValues("latest"), id: \.aqlKey) { value in
                Text(value.displayName).tag(value.aqlKey)
            }
        }
    }

    @ViewBuilder
    private var sortPicker: some View {
        Picker("Sort By", selection: $filters.sort) {
            ForEach(presetValues("sort"), id: \.aqlKey) { value in
                Text(value.displayName).tag(value.aqlKey)
            }
        }
    }

    @ViewBuilder
    private var orderPicker: some View {
        Picker("Sort Order", selection: $filters.order) {
            ForEach(presetValues("order"), id: \.aqlKey) { value in
                Text(value.displayName).tag(value.aqlKey)
            }
        }
    }

    private func presetValues(_ type: String) -> [Assembly64Client.AQLPresetValue] {
        presets.first { $0.type == type }?.values ?? []
    }

    private var groupedCategories: [(String, [Assembly64Client.Category])] {
        Dictionary(grouping: categories) { $0.groupingName ?? "Other" }
            .sorted { $0.key < $1.key }
    }

    private var canSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedCategory != nil || filters.hasActiveFilters
    }

    private var defaultSavedSearchName: String {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if !filters.latest.isEmpty {
            let latestName = presetValues("latest").first {
                $0.aqlKey == filters.latest
            }?.displayName ?? "releases"
            return "Latest \(latestName)"
        }
        if let selectedCategory {
            return selectedCategory.description ?? selectedCategory.name
        }
        return "Assembly64 Search"
    }

    // MARK: - Results

    private var resultsPane: some View {
        VStack(spacing: 0) {
            Table(displayedResults, selection: $selectedResult) {
                TableColumn("") { result in
                    Button {
                        library.toggleFavorite(result)
                    } label: {
                        Image(systemName: library.isFavorite(result)
                              ? "star.fill" : "star")
                            .foregroundStyle(library.isFavorite(result)
                                             ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(library.isFavorite(result)
                          ? "Remove from favorites" : "Add to favorites")
                }
                .width(28)

                TableColumn("Name") { result in
                    Text(result.name)
                }
                .width(min: 160, ideal: 240, max: 300)

                TableColumn("Group") { result in
                    Text(result.displayGroup)
                }
                .width(min: 80, ideal: 120, max: 160)

                TableColumn("Year") { result in
                    Text(result.year.map { $0 == 0 ? "" : String($0) } ?? "")
                }
                .width(min: 48, ideal: 56, max: 64)

                TableColumn("Rating") { result in
                    Text(result.displayRating)
                }
                .width(min: 48, ideal: 56, max: 64)
            }
            .onChange(of: selectedResult) { loadSelectedItem() }

            statusBar
        }
        // Header + approximately ten standard table rows + status bar.
        // Keeping this fixed makes the browser compact and gives the detail
        // pane the remaining window height instead of showing dozens of
        // results at once.
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }

    private var statusBar: some View {
        HStack {
            switch scope {
            case .search:
                searchStatus
            case .favorites:
                Label("\(library.favorites.count) favorites", systemImage: "star.fill")
                    .foregroundStyle(.secondary)
            case .recent:
                Label("\(library.recents.count) recently viewed", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let loadStatus {
                Text(loadStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Label(targetLabel, systemImage: "scope")
                .foregroundStyle(.secondary)
                .help("Run/Mount target")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var searchStatus: some View {
        switch searchState {
        case .idle:
            Text("Enter a name or choose filters.")
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
    }

    // MARK: - Item details and files

    private var filesPane: some View {
        Group {
            if let selectedItem {
                HStack(spacing: 0) {
                    itemSummary(selectedItem)
                        // This column must never be compressed by long file
                        // names or action buttons in the neighbouring list.
                        // A plain fixed frame still participates in HStack
                        // compression; fixedSize + layoutPriority makes the
                        // full 250pt metadata panel non-negotiable.
                        .frame(minWidth: 250, idealWidth: 250, maxWidth: 250)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    Divider()
                    entryList(selectedItem)
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView {
                    Label(scope == .favorites && library.favorites.isEmpty
                          ? "No Favorites Yet" : "No Item Selected",
                          systemImage: scope == .favorites
                          ? "star" : "square.stack.3d.up")
                } description: {
                    Text(scope == .favorites && library.favorites.isEmpty
                         ? "Star search results to keep them here."
                         : "Select a result to see metadata and files.")
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 250)
    }

    private func itemSummary(_ result: Assembly64Client.SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let previewURL = itemMetadata?.imageURLs.first
                ?? fallbackPreview?.imageURL {
                AsyncImage(url: previewURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        previewPlaceholder
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    @unknown default:
                        previewPlaceholder
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if metadataLoading {
                ProgressView("Loading metadata…")
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                previewPlaceholder
            }

            Text(itemMetadata?.name ?? result.name)
                .font(.headline)
                .lineLimit(2)

            if !result.displayGroup.isEmpty {
                Label(result.displayGroup, systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let year = result.year, year > 0 {
                Label(String(year), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !result.displayRating.isEmpty {
                Label("\(result.displayRating) / 10", systemImage: "star")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let released = itemMetadata?.releaseDate ?? result.released,
               !released.isEmpty {
                Text("Released \(released)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(library.isFavorite(result) ? "Favorited" : "Favorite",
                       systemImage: library.isFavorite(result)
                       ? "star.fill" : "star") {
                    library.toggleFavorite(result)
                }
                .controlSize(.small)

                if let sourceURL = itemMetadata?.sourceURL
                    ?? fallbackPreview?.sourceURL {
                    Link(destination: sourceURL) {
                        Label("Source", systemImage: "safari")
                    }
                    .controlSize(.small)
                }
            }

            Spacer()
        }
        .padding(12)
    }

    private var previewPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
    }

    private func entryList(_ result: Assembly64Client.SearchResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files")
                    .font(.headline)
                Text("\(entries.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save ZIP…", systemImage: "archivebox") {
                    saveArchive(result)
                }
                .controlSize(.small)
                .disabled(entriesLoading || entries.isEmpty)
                .help("Download every file in this entry as one ZIP archive")
                Button("Inspect ZIP…", systemImage: "doc.zipper") {
                    inspectArchive(result)
                }
                .controlSize(.small)
                .disabled(entriesLoading || entries.isEmpty)
                .help("Safely inspect and run supported files inside the complete entry ZIP")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if entriesLoading {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("No Files",
                                       systemImage: "doc.questionmark")
            } else {
                List(entries) { entry in
                    HStack {
                        Image(systemName: icon(for: entry.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.filename)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 6) {
                                Text(ByteCountFormatter.string(
                                    fromByteCount: Int64(entry.size),
                                    countStyle: .file))
                                if let action = library.rememberedAction(
                                    result: result, entry: entry) {
                                    Label(actionLabel(action),
                                          systemImage: "clock.arrow.circlepath")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        actions(for: entry, result: result)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for entry: Assembly64Client.FileEntry,
                         result: Assembly64Client.SearchResult) -> some View {
        switch entry.kind {
        case .prg:
            Button("Run") {
                load(entry, result: result, behavior: .mountOnly, action: "run")
            }
            .disabled(targetDevices.isEmpty)
        case .disk:
            Button("Mount & Run") {
                load(entry, result: result,
                     behavior: .mountAndRun, action: "mountAndRun")
            }
            .disabled(targetDevices.isEmpty)
            Button("Mount") {
                load(entry, result: result, behavior: .mountOnly, action: "mount")
            }
            .disabled(targetDevices.isEmpty)
        case .sid:
            Button("Play") {
                load(entry, result: result, behavior: .mountOnly, action: "play")
            }
            .disabled(targetDevices.isEmpty)
        case .cartridge:
            Button("Run") {
                load(entry, result: result, behavior: .mountOnly, action: "run")
            }
            .disabled(targetDevices.isEmpty)
        case .other:
            Text("Preview only")
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

    private func actionLabel(_ action: String) -> String {
        switch action {
        case "mountAndRun": return "Mount & Run"
        case "mount": return "Mount"
        case "play": return "Play"
        default: return "Run"
        }
    }

    // MARK: - Search actions

    private func loadReferenceData() async {
        async let categoryRequest = try? client.categories()
        async let presetRequest = try? client.presets()
        categories = await categoryRequest ?? []
        presets = await presetRequest ?? []
    }

    private func runSearch(text: String? = nil,
                           category: Assembly64Client.Category? = nil,
                           filterSet: Assembly64SearchFilters? = nil) {
        let searchText = text ?? self.searchText
        let category = category ?? selectedCategory
        let filterSet = filterSet ?? filters
        let queryModel = Assembly64SearchQuery(
            text: searchText,
            categoryName: category?.name,
            filters: filterSet)
        guard queryModel.hasConstraint else {
            searchState = .idle
            searchResults = []
            return
        }

        scope = .search
        searchTask?.cancel()
        selectionTask?.cancel()
        searchState = .searching
        searchResults = []
        clearSelection()
        hasMoreResults = false

        let query = queryModel.aql
        loadedQuery = query

        searchTask = Task {
            do {
                let found = try await client.search(
                    query: query, offset: 0, limit: Self.pageSize)
                guard !Task.isCancelled else { return }
                searchResults = found
                searchState = .done(count: found.count)
                hasMoreResults = found.count == Self.pageSize
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    private func loadMoreResults() {
        guard !isLoadingMore, hasMoreResults, scope == .search else { return }
        isLoadingMore = true
        let query = loadedQuery
        let offset = searchResults.count
        Task {
            defer { isLoadingMore = false }
            do {
                let found = try await client.search(
                    query: query, offset: offset, limit: Self.pageSize)
                searchResults.append(contentsOf: found)
                searchState = .done(count: searchResults.count)
                hasMoreResults = found.count == Self.pageSize
            } catch {
                loadStatus = "Load more failed: \(error.localizedDescription)"
            }
        }
    }

    private func saveCurrentSearch() {
        library.saveSearch(
            name: savedSearchName,
            text: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryID: selectedCategory?.id,
            filters: filters)
    }

    private func apply(_ saved: Assembly64LibraryStore.SavedSearch) {
        let category = categories.first { $0.id == saved.categoryID }
        searchText = saved.text
        selectedCategory = category
        filters = saved.filters
        runSearch(text: saved.text, category: category, filterSet: saved.filters)
    }

    // MARK: - Selection and loading

    private func clearSelection() {
        selectionTask?.cancel()
        selectedResult = nil
        entries = []
        itemMetadata = nil
        fallbackPreview = nil
        entriesLoading = false
        metadataLoading = false
    }

    private func loadSelectedItem() {
        selectionTask?.cancel()
        guard let result = selectedItem else {
            entries = []
            itemMetadata = nil
            return
        }

        library.recordOpened(result)
        entries = []
        entriesLoading = true
        itemMetadata = nil
        fallbackPreview = nil
        metadataLoading = true
        let selectedID = result.id
        let isCSDB = categories.first {
            $0.id == result.category
        }?.type?.lowercased() == "csdb"

        selectionTask = Task {
            async let cachedMetadataRequest = Assembly64Cache.shared.metadata(
                for: result.libraryKey)
            async let cachedPreviewRequest = Assembly64Cache.shared.preview(
                for: result.libraryKey)
            let cachedMetadata = await cachedMetadataRequest
            let cachedPreview = await cachedPreviewRequest
            guard !Task.isCancelled, selectedResult == selectedID else { return }
            if let cachedMetadata {
                itemMetadata = cachedMetadata
            }
            fallbackPreview = cachedPreview
            metadataLoading = cachedMetadata == nil && cachedPreview == nil

            async let filesRequest = client.entries(
                itemID: result.itemID, categoryID: result.category)

            var fetchedMetadata: Assembly64Client.Metadata?
            if cachedMetadata == nil {
                fetchedMetadata = try? await client.metadata(
                    itemID: result.itemID, categoryID: result.category)
            }
            let resolvedMetadata = fetchedMetadata ?? cachedMetadata

            var fetchedPreview: CSDBPreviewClient.Preview?
            if isCSDB, cachedPreview == nil,
               resolvedMetadata?.sourceURL == nil
                || resolvedMetadata?.imageURLs.isEmpty != false {
                fetchedPreview = try? await CSDBPreviewClient().preview(
                    releaseID: result.itemID)
            }

            do {
                let loadedEntries = try await filesRequest
                guard !Task.isCancelled, selectedResult == selectedID else { return }
                entries = loadedEntries
                if let fetchedMetadata {
                    itemMetadata = fetchedMetadata
                    await Assembly64Cache.shared.store(
                        fetchedMetadata, for: result.libraryKey)
                }
                if let fetchedPreview {
                    fallbackPreview = fetchedPreview
                    await Assembly64Cache.shared.store(
                        fetchedPreview, for: result.libraryKey)
                }
                entriesLoading = false
                metadataLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, selectedResult == selectedID else { return }
                entriesLoading = false
                metadataLoading = false
                loadStatus = "Files: \(error.localizedDescription)"
            }
        }
    }

    private func load(_ entry: Assembly64Client.FileEntry,
                      result: Assembly64Client.SearchResult,
                      behavior: DeviceSession.MountBehavior,
                      action: String) {
        let targets = targetDevices
        guard !targets.isEmpty else { return }
        loadStatus = "Downloading \(entry.filename)…"

        Task {
            do {
                let data = try await client.download(
                    itemID: result.itemID,
                    categoryID: result.category,
                    fileID: entry.id)
                loadStatus = "Sending to \(targets.count) target"
                    + (targets.count == 1 ? "…" : "s…")
                let successes = await withTaskGroup(
                    of: Bool.self, returning: Int.self
                ) { group in
                    for device in targets {
                        let session = sessionProvider(device)
                        group.addTask {
                            await session.loadData(
                                data, filename: entry.filename,
                                mountBehavior: behavior) != nil
                        }
                    }
                    var count = 0
                    for await success in group where success { count += 1 }
                    return count
                }
                loadStatus = successes == targets.count
                    ? "Completed on \(successes) target"
                        + (successes == 1 ? "" : "s")
                    : "Completed on \(successes) of \(targets.count) targets"
                if successes > 0 {
                    library.rememberAction(
                        action, result: result, entry: entry)
                }
            } catch {
                loadStatus = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    private func inspectArchive(_ result: Assembly64Client.SearchResult) {
        loadStatus = "Downloading archive for inspection…"
        Task {
            do {
                let data = try await client.downloadArchive(
                    itemID: result.itemID, categoryID: result.category)
                let items = try await Task.detached {
                    try Assembly64ArchiveInspector.inspect(data)
                }.value
                archivePreview = ArchivePreview(
                    result: result, data: data, items: items)
                loadStatus = nil
            } catch {
                loadStatus = "ZIP inspection failed: \(error.localizedDescription)"
            }
        }
    }

    private func archiveInspector(_ preview: ArchivePreview) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.result.name)
                        .font(.headline)
                    Text("\(preview.items.count) safe archive entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { archivePreview = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            List(preview.items) { item in
                HStack {
                    Image(systemName: archiveIcon(item))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.normalizedPath)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(item.uncompressedSize),
                            countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.isSupportedByDevice {
                        archiveActions(item, preview: preview)
                    } else {
                        Text("Preview only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    @ViewBuilder
    private func archiveActions(_ item: Assembly64ArchiveInspector.Item,
                                preview: ArchivePreview) -> some View {
        switch item.fileExtension {
        case "d64", "g64", "d71", "g71", "d81":
            Button("Mount & Run") {
                loadArchiveItem(
                    item, preview: preview, behavior: .mountAndRun)
            }
            Button("Mount") {
                loadArchiveItem(
                    item, preview: preview, behavior: .mountOnly)
            }
        case "sid":
            Button("Play") {
                loadArchiveItem(item, preview: preview, behavior: .mountOnly)
            }
        default:
            Button("Run") {
                loadArchiveItem(item, preview: preview, behavior: .mountOnly)
            }
        }
    }

    private func loadArchiveItem(_ item: Assembly64ArchiveInspector.Item,
                                 preview: ArchivePreview,
                                 behavior: DeviceSession.MountBehavior) {
        let targets = targetDevices
        guard !targets.isEmpty else { return }
        loadStatus = "Extracting \(item.filename)…"

        Task {
            do {
                let data = try await Task.detached {
                    try Assembly64ArchiveInspector.extract(
                        item, from: preview.data)
                }.value
                archivePreview = nil
                loadStatus = "Sending to \(targets.count) target"
                    + (targets.count == 1 ? "…" : "s…")
                let successes = await withTaskGroup(
                    of: Bool.self, returning: Int.self
                ) { group in
                    for device in targets {
                        let session = sessionProvider(device)
                        group.addTask {
                            await session.loadData(
                                data, filename: item.filename,
                                mountBehavior: behavior) != nil
                        }
                    }
                    var count = 0
                    for await success in group where success { count += 1 }
                    return count
                }
                loadStatus = "Completed on \(successes) of "
                    + "\(targets.count) targets"
            } catch {
                loadStatus = "ZIP extraction failed: \(error.localizedDescription)"
            }
        }
    }

    private func archiveIcon(_ item: Assembly64ArchiveInspector.Item) -> String {
        switch item.fileExtension {
        case "prg": return "doc.badge.play"
        case "d64", "g64", "d71", "g71", "d81": return "opticaldisc"
        case "sid": return "music.note"
        case "crt": return "memorychip"
        default: return "doc"
        }
    }

    private func saveArchive(_ result: Assembly64Client.SearchResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let safeName = result.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeName).zip"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            loadStatus = "Downloading \(safeName).zip…"
            Task {
                do {
                    let data = try await client.downloadArchive(
                        itemID: result.itemID, categoryID: result.category)
                    try data.write(to: url, options: .atomic)
                    loadStatus = "Saved \(url.lastPathComponent)"
                } catch {
                    loadStatus = "ZIP failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
