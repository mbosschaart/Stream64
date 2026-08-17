import SwiftUI
import UniformTypeIdentifiers

/// Interactive browser for the High Voltage SID Collection. Searches are
/// deliberately constrained to the same user-initiated flow as HVSC's web UI;
/// this view never crawls, prefetches, or pages through its collection.
struct HVSCView: View {
    @EnvironmentObject private var deviceStore: DeviceStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: HVSCLibraryStore
    @EnvironmentObject private var sidFlowRecommendations: SIDFlowRecommendationStore

    let sessionProvider: (UltimateDevice) -> DeviceSession
    private let client = HVSCClient()

    @State private var query = ""
    @State private var filters = HVSCClient.SearchFilters()
    @State private var results: [HVSCClient.SearchResult] = []
    @State private var collectionResults: [HVSCClient.SearchResult] = []
    @State private var loadedCollection: HVSCClient.SearchFilters.Collection?
    @State private var selectedID: Int?
    @State private var detail: HVSCClient.TuneDetail?
    @State private var searchStatus = "Enter at least three characters to search HVSC."
    @State private var isSearching = false
    @State private var isLoadingDetail = false
    @State private var isPlaying = false
    @State private var playbackStatus: String?
    @State private var actionTarget: DeviceActionTarget?
    @State private var searchTask: Task<Void, Never>?
    @State private var detailTask: Task<Void, Never>?
    @State private var showingImporter = false
    @State private var showingPlaylist = false
    @State private var collectionVersion: Int?
    @State private var sidCompatibility: SIDCompatibility?
    @State private var isCheckingSIDCompatibility = false
    @State private var isFixingSIDAddress = false

    private struct SIDCompatibility: Equatable {
        let message: String
        let desiredSecondAddress: UInt16?
        let fixableDevices: [UltimateDevice]

        var canFixAddress: Bool {
            desiredSecondAddress != nil && !fixableDevices.isEmpty
        }
    }

    private var selectedResult: HVSCClient.SearchResult? {
        results.first { $0.id == selectedID }
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
            detailsPane
        }
        .searchable(
            text: $query,
            placement: .toolbar,
            prompt: "Search HVSC (e.g. turrican)")
        .onSubmit(of: .search) {
            scheduleSearch(immediately: true)
        }
        .onChange(of: query) {
            scheduleSearch(immediately: false)
        }
        .onChange(of: filters.collection) {
            scheduleSearch(immediately: true, reloadCollection: true)
        }
        .onChange(of: actionTarget) {
            if let detail {
                refreshSIDCompatibility(for: detail)
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle("HVSC SID Browser")
        .frame(
            minWidth: 880, idealWidth: 980, maxWidth: .infinity,
            minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .task {
            if actionTarget == nil, let id = deviceStore.selectedDeviceID {
                actionTarget = .device(id)
            }
            await loadCollectionVersion()
        }
        .onDisappear {
            searchTask?.cancel()
            detailTask?.cancel()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            library.importSonglengths(from: url)
        }
        .sheet(isPresented: $showingPlaylist) {
            playlistSheet
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Search Field", selection: $filters.field) {
                ForEach(HVSCClient.SearchFilters.Field.allCases) { field in
                    Text(field.label).tag(field)
                }
            }
            .frame(width: 120)
        }

        ToolbarItem(placement: .navigation) {
            Picker("Collection", selection: $filters.collection) {
                ForEach(HVSCClient.SearchFilters.Collection.allCases) {
                    collection in
                    Text(collection.label).tag(collection)
                }
            }
            .frame(width: 150)
            .help("Browse HVSC's conventionally named multi-SID tune sets")
        }

        ToolbarItem {
            Menu {
                Picker("SID Model", selection: $filters.model) {
                    ForEach(HVSCClient.SearchFilters.SIDModel.allCases) { model in
                        Text(model.label).tag(model)
                    }
                }
                Picker("Video Standard", selection: $filters.clock) {
                    ForEach(HVSCClient.SearchFilters.Clock.allCases) { clock in
                        Text(clock.label).tag(clock)
                    }
                }
                Divider()
                Picker("Release Year", selection: $filters.year) {
                    Text("Any Year").tag(nil as Int?)
                    ForEach(Array(1982...Calendar.current.component(.year, from: Date())).reversed(), id: \.self) {
                        Text(String($0)).tag($0 as Int?)
                    }
                }
                Divider()
                Button("Apply Filters") {
                    scheduleSearch(immediately: true, reloadCollection: true)
                }
                Button("Clear Filters") {
                    filters = .init()
                    scheduleSearch(immediately: true)
                }
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filter HVSC search results")
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
            .help("Device target for SID playback")
        }

        ToolbarItem {
            Menu {
                Button("Update Songlengths Database", systemImage: "arrow.down.circle") {
                    Task {
                        await library.updateSonglengths(using: client)
                    }
                }
                Button("Import Songlengths Database…", systemImage: "square.and.arrow.down") {
                    showingImporter = true
                }
                if let info = library.songlengthInfo {
                    Divider()
                    Text(songlengthDescription(info))
                }
                if let status = library.updateStatus {
                    Text(status)
                }
            } label: {
                Label("Song Lengths", systemImage: "timer")
            }
            .help("Update or import HVSC Songlengths.md5")
        }

        ToolbarItem {
            Button {
                showingPlaylist = true
            } label: {
                Label(
                    "Playlist (\(library.playlist.count))",
                    systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .help("Show the persistent HVSC playlist")
        }

        ToolbarItem {
            Button {
                Stream64ToolWindows.showSIDRadio()
            } label: {
                Label("SID Station", systemImage: "dot.radiowaves.left.and.right")
            }
                .help("Open your personal SID recommendation station")
        }

        ToolbarItem {
            Link(destination: HVSCClient.baseURL) {
                Label("Open HVSC", systemImage: "safari")
            }
            .help("Open the official HVSC website")
        }
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            Table(results, selection: $selectedID) {
                TableColumn("Title") { result in
                    resultCell(result.title, result: result)
                }
                .width(min: 180, ideal: 300)
                TableColumn("Author") { result in
                    resultCell(result.author, result: result)
                }
                .width(min: 130, ideal: 220)
                TableColumn("Release") { result in
                    resultCell(result.released, result: result)
                }
                .width(min: 130, ideal: 220)
            }
            .onChange(of: selectedID) {
                loadDetail()
            }

            HStack {
                if isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching HVSC…")
                } else {
                    Text(searchStatus)
                }
                Spacer()
                if let version = collectionVersion {
                    Text("HVSC #\(version)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(height: 280)
    }

    private func resultCell(
        _ text: String,
        result: HVSCClient.SearchResult
    ) -> some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                ExclusiveGesture(
                    TapGesture(count: 2),
                    TapGesture()
                )
                .onEnded { gesture in
                    selectedID = result.id
                    switch gesture {
                    case .first:
                        playSelectedResult(id: result.id)
                    case .second:
                        break
                    }
                }
            )
    }

    @ViewBuilder
    private var detailsPane: some View {
        if isLoadingDetail {
            ProgressView("Loading tune details…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            HStack(alignment: .top, spacing: 0) {
                metadata(detail)
                    .frame(minWidth: 300, idealWidth: 350, maxWidth: 390)
                Divider()
                playbackPanel(detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                "No Tune Selected",
                systemImage: "music.note.list",
                description: Text("Select an HVSC search result to see its SID details."))
        }
    }

    private func metadata(_ detail: HVSCClient.TuneDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Label(detail.author, systemImage: "person")
            Label(detail.released, systemImage: "calendar")
            Divider()
            LabeledContent("Format", value: "\(detail.fileFormat) v\(detail.fileFormatVersion)")
            LabeledContent("Path", value: detail.relativePath)
                .lineLimit(2)
            LabeledContent("Songs", value: "\(detail.numberOfSongs) (starts \(detail.startSong))")
            LabeledContent("Clock", value: detail.videoStandard)
            LabeledContent("SID", value: detail.sidRequirements)
            LabeledContent("Load", value: "$\(detail.loadAddress)")
            LabeledContent("Init / Play", value: "$\(detail.initAddress) / $\(detail.playAddress)")
            if detail.playsidSpecific {
                Label("PlaySID-specific tune", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if detail.fileFormat == "RSID" {
                Label("RSID: real-C64 environment required", systemImage: "cpu")
                    .foregroundStyle(.orange)
            }
            if detail.sid2BaseAddress != nil || detail.sid3BaseAddress != nil {
                Label("Additional SID hardware required", systemImage: "waveform")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.callout)
        .padding(14)
    }

    private func playbackPanel(_ detail: HVSCClient.TuneDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback")
                .font(.headline)
            sidCompatibilityPill
            if let durations = currentDurations {
                Text("Song lengths")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(durations.enumerated()), id: \.offset) { index, milliseconds in
                            HStack {
                                Text("Song \(index + 1)")
                                Spacer()
                                Text(formatDuration(milliseconds))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            } else if library.songlengthInfo != nil {
                Text("No matching song-length entry is available for this tune.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Update or import Songlengths.md5 to show subtune durations.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Play on \(targetLabel)", systemImage: "play.fill") {
                    play(detail)
                }
                .disabled(isPlaying || targetDevices.isEmpty)
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    library.addToPlaylist(detail)
                }
                .disabled(library.playlist.contains { $0.tune.id == detail.id })
                Button(
                    sidFlowRecommendations.likedKeys.contains(sidFlowKey(for: detail))
                        ? "Liked" : "Like for SID Station",
                    systemImage: "heart")
                {
                    sidFlowRecommendations.like(sidFlowKey(for: detail))
                }
                .disabled(sidFlowRecommendations.likedKeys.contains(sidFlowKey(for: detail)))
                if isPlaying {
                    ProgressView().controlSize(.small)
                }
            }

            if let playbackStatus {
                Text(playbackStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(14)
    }

    @ViewBuilder
    private var sidCompatibilityPill: some View {
        if isCheckingSIDCompatibility {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking SID configuration…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let sidCompatibility {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(sidCompatibility.message)
                    .lineLimit(2)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.15), in: Capsule())
        }
    }

    private var playlistSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HVSC Playlist")
                    .font(.headline)
                Text("\(library.playlist.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", role: .destructive) {
                    library.clearPlaylist()
                }
                .disabled(library.playlist.isEmpty)
            }
            .padding(14)

            Divider()

            if library.playlist.isEmpty {
                ContentUnavailableView(
                    "Playlist Is Empty",
                    systemImage: "text.badge.plus",
                    description: Text("Select an HVSC tune and choose Add to Playlist."))
            } else {
                List {
                    ForEach(Array(library.playlist.enumerated()), id: \.element.id) {
                        index, entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.tune.title)
                                    .lineLimit(1)
                                Text(entry.tune.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                play(entry.tune)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Play on \(targetLabel)")
                            Button {
                                library.movePlaylistEntry(from: index, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                            Button {
                                library.movePlaylistEntry(from: index, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == library.playlist.count - 1)
                            Button(role: .destructive) {
                                library.removeFromPlaylist(entry)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            play(entry.tune)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("Double-click a tune or use Play to send it to \(targetLabel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    showingPlaylist = false
                }
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var currentDurations: [Int]? {
        guard let detail, let data = downloadedSIDForDetail[detail.id] else {
            return nil
        }
        return library.durations(for: data)
    }

    /// Cache just the selected downloaded SID in memory. It avoids a redundant
    /// download when the user views song lengths and immediately presses Play.
    @State private var downloadedSIDForDetail: [Int: Data] = [:]

    private func scheduleSearch(immediately: Bool) {
        scheduleSearch(immediately: immediately, reloadCollection: false)
    }

    private func scheduleSearch(
        immediately: Bool,
        reloadCollection: Bool
    ) {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filters = filters
        let collection = filters.collection

        if collection != .all {
            if !reloadCollection, loadedCollection == collection {
                applyCollectionResults(for: query, collection: collection)
                return
            }
            searchTask = Task {
                if !immediately {
                    try? await Task.sleep(for: .milliseconds(350))
                }
                guard !Task.isCancelled else { return }
                isSearching = true
                defer { isSearching = false }
                do {
                    let found = try await client.searchCollection(
                        collection, filters: filters)
                    guard !Task.isCancelled else { return }
                    collectionResults = found
                    loadedCollection = collection
                    applyCollectionResults(for: query, collection: collection)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    collectionResults = []
                    loadedCollection = nil
                    clearSelectedResult()
                    searchStatus = error.localizedDescription
                }
            }
            return
        }

        collectionResults = []
        loadedCollection = nil
        guard query.count >= 3 else {
            clearSelectedResult()
            searchStatus = "Enter at least three characters to search HVSC."
            return
        }
        searchTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let found = try await client.search(query: query, filters: filters)
                guard !Task.isCancelled else { return }
                results = found
                clearSelectedResult()
                searchStatus = "\(found.count) result\(found.count == 1 ? "" : "s")"
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchStatus = error.localizedDescription
            }
        }
    }

    private func applyCollectionResults(
        for query: String,
        collection: HVSCClient.SearchFilters.Collection
    ) {
        let filtered = collectionResults.filter { $0.matches(query) }
        results = filtered
        clearSelectedResult()
        let total = collectionResults.count
        let prefix = query.isEmpty ? "" : "\(filtered.count) of "
        searchStatus = "\(prefix)\(total) \(collection.label.lowercased())"
    }

    private func clearSelectedResult() {
        selectedID = nil
        detail = nil
        sidCompatibility = nil
        downloadedSIDForDetail.removeAll()
    }

    private func loadDetail() {
        detailTask?.cancel()
        downloadedSIDForDetail.removeAll()
        guard let id = selectedID else {
            detail = nil
            sidCompatibility = nil
            return
        }
        isLoadingDetail = true
        detailTask = Task {
            defer { isLoadingDetail = false }
            do {
                let loaded = try await client.details(id: id)
                guard !Task.isCancelled, selectedID == id else { return }
                detail = loaded
                refreshSIDCompatibility(for: loaded)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, selectedID == id else { return }
                detail = nil
                sidCompatibility = nil
                playbackStatus = error.localizedDescription
            }
        }
    }

    private func play(_ detail: HVSCClient.TuneDetail) {
        let targets = targetDevices
        guard !targets.isEmpty else { return }
        isPlaying = true
        playbackStatus = "Downloading \(detail.filename)…"
        Task {
            defer { isPlaying = false }
            do {
                let data: Data
                if let cached = downloadedSIDForDetail[detail.id] {
                    data = cached
                } else {
                    data = try await client.downloadSID(id: detail.id)
                    downloadedSIDForDetail[detail.id] = data
                }
                let header = try SIDHeader(data: data)
                playbackStatus = compatibilityMessage(
                    header: header, detail: detail)
                    ?? "Sending to \(targets.count) target"
                    + (targets.count == 1 ? "…" : "s…")
                let successes = await withTaskGroup(
                    of: Bool.self,
                    returning: Int.self
                ) { group in
                    for device in targets {
                        let session = sessionProvider(device)
                        group.addTask {
                            await session.loadData(
                                data,
                                filename: detail.filename) != nil
                        }
                    }
                    var count = 0
                    for await success in group where success { count += 1 }
                    return count
                }
                playbackStatus = successes == targets.count
                    ? "Playing \(detail.filename) on \(successes) target"
                    + (successes == 1 ? "." : "s.")
                    : "Playing on \(successes) of \(targets.count) targets."
            } catch {
                playbackStatus = "Play failed: \(error.localizedDescription)"
            }
        }
    }

    /// Compare the selected SID's declared hardware with the current target
    /// configuration. This is advisory: a warning never prevents playback.
    private func refreshSIDCompatibility(for detail: HVSCClient.TuneDetail) {
        let targets = targetDevices
        guard !targets.isEmpty else {
            sidCompatibility = nil
            return
        }
        guard detail.sid2BaseAddress != nil || detail.sid3BaseAddress != nil else {
            sidCompatibility = nil
            return
        }
        let count = detail.sid3BaseAddress == nil ? "2-SID" : "3-SID"
        sidCompatibility = SIDCompatibility(
            message: "\(count) routing will be configured and saved before playback.",
            desiredSecondAddress: nil,
            fixableDevices: [])
    }

    /// User-confirmed fix: only changes the address of an already-enabled,
    /// detected second SID and persists that address in Ultimate configuration.
    private func fixSecondSIDAddress(
        _ address: UInt16,
        on devices: [UltimateDevice]
    ) {
        guard !devices.isEmpty else { return }
        isFixingSIDAddress = true
        Task {
            defer { isFixingSIDAddress = false }
            var failures: [String] = []
            for device in devices {
                do {
                    try await UltimateAPIClient(
                        device: device).setSecondSIDAddress(address)
                } catch {
                    failures.append("\(device.name): \(error.localizedDescription)")
                }
            }
            if let detail {
                refreshSIDCompatibility(for: detail)
            }
            playbackStatus = failures.isEmpty
                ? "Updated second SID address to \(Self.addressLabel(address))."
                : "SID address fix failed: \(failures.joined(separator: " "))"
        }
    }

    /// A double-click mirrors the familiar library-browser action: fetch
    /// details if selection has not finished loading yet, then play using the
    /// current one-device / all-connected target selection.
    private func playSelectedResult() {
        guard let id = selectedID else { return }
        playSelectedResult(id: id)
    }

    private func playSelectedResult(id: Int) {
        guard !isPlaying, !isLoadingDetail else { return }
        if let detail, detail.id == id {
            play(detail)
            return
        }
        isLoadingDetail = true
        playbackStatus = "Loading tune details…"
        Task {
            defer { isLoadingDetail = false }
            do {
                let loaded = try await client.details(id: id)
                guard selectedID == id else { return }
                detail = loaded
                play(loaded)
            } catch {
                playbackStatus = "Play failed: \(error.localizedDescription)"
            }
        }
    }

    private func loadCollectionVersion() async {
        collectionVersion = try? await client.collectionVersion().version
    }

    private func compatibilityMessage(
        header: SIDHeader,
        detail: HVSCClient.TuneDetail
    ) -> String? {
        guard header.numberOfSongs != detail.numberOfSongs
            || header.format.rawValue != detail.fileFormat
        else { return nil }
        return "HVSC metadata differs from the downloaded SID; using the downloaded file."
    }

    private func songlengthDescription(_ info: HVSCLibraryStore.SonglengthInfo) -> String {
        let version = info.hvscVersion.map { "HVSC #\($0)" } ?? "Imported"
        return "\(version) · \(info.entryCount) tunes"
    }

    private func sidFlowKey(for detail: HVSCClient.TuneDetail) -> SIDFlowTrackKey {
        // SIDFlow identifies a sub-tune; the selected default tune is the
        // strongest available intent signal in the current HVSC browser.
        .init(
            sidPath: detail.relativePath.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")),
            songIndex: detail.startSong)
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let remainder = milliseconds % 1_000
        if remainder == 0 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        return String(format: "%d:%02d.%03d", minutes, seconds, remainder)
    }

    private static func parseSIDAddress(_ value: String?) -> UInt16? {
        guard var value else { return nil }
        value = value.replacingOccurrences(of: "$", with: "")
        return UInt16(value, radix: 16)
    }

    private static func requiredModel(
        needs6581: Bool,
        needs8580: Bool
    ) -> String? {
        switch (needs6581, needs8580) {
        case (true, false): return "6581"
        case (false, true): return "8580"
        default: return nil
        }
    }

    private static func addressLabel(_ address: UInt16) -> String {
        String(format: "$%04X", address)
    }
}
