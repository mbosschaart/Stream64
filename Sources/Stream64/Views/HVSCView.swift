import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Searches and plays only the user's extracted HVSC corpus. The manifest is
/// used solely to announce collection releases; it is never a SID API.
struct HVSCView: View {
    @EnvironmentObject private var deviceStore: DeviceStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var localLibrary: HVSCLocalLibrary
    @EnvironmentObject private var songlengths: HVSCLibraryStore
    @EnvironmentObject private var recommendations: SIDFlowRecommendationStore
    let sessionProvider: (UltimateDevice) -> DeviceSession

    @State private var query = ""
    @State private var selection: String?
    @State private var showingFolderPicker = false
    @State private var showingInstallDestinationPicker = false
    @State private var installUpdate = false
    @State private var pendingUpdateDestination: URL?
    @State private var showingUpdateConfirmation = false
    @State private var installTask: Task<Void, Never>?
    @State private var playing = false
    @State private var status = ""
    @State private var playlistPlaybackIndex: Int?
    @State private var playlistShuffle = false
    @State private var playlistLoop = false
    @State private var playlistPlaybackTask: Task<Void, Never>?
    @State private var browsePath = ""
    @State private var sortOrder = [KeyPathComparator(\LocalHVSCTune.title)]
    @State private var showingPlaylist = false
    @State private var playlistSelection: String?

    private var results: [LocalHVSCTune] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           collection == .all {
            return localLibrary.tunes(directlyIn: browsePath)
        }
        return localLibrary.search(query, collection: collection)
    }
    private var sortedResults: [LocalHVSCTune] {
        results.sorted(using: sortOrder)
    }
    @State private var collection: HVSCClient.SearchFilters.Collection = .all
    private var target: UltimateDevice? { deviceStore.selectedDevice }
    private var selectedTune: LocalHVSCTune? {
        selection.flatMap { id in localLibrary.tunes.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !localLibrary.isReady {
                configurationView
            } else {
                browser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("HVSC Browser")
        .searchable(text: $query, placement: .toolbar, prompt: "Search your local HVSC library")
        .toolbar {
            ToolbarItem {
                Button("Choose HVSC Folder…", systemImage: "folder") {
                    presentFolderPicker(forInstall: false)
                }
                .help("Choose the extracted C64Music folder to index")
            }
            ToolbarItem {
                Button("Rebuild Index", systemImage: "arrow.clockwise") {
                    localLibrary.rebuildIndex()
                }
                .disabled(!localLibrary.isReady)
                .help("Rebuild the local HVSC search index")
            }
            ToolbarItem {
                Button("Check Release", systemImage: "arrow.down.circle") {
                    Task { await localLibrary.fetchManifest() }
                }
                .help("Check for the latest HVSC release")
            }
            if localLibrary.isReady {
                ToolbarItem {
                    Button("Update HVSC…", systemImage: "arrow.triangle.2.circlepath") {
                        installUpdate = true
                        presentFolderPicker(forInstall: true)
                    }
                    .disabled(!localLibrary.canInstallUpdate || localLibrary.isInstalling)
                    .help(updateHelp)
                }
            }
            if localLibrary.isInstalling {
                ToolbarItem {
                    Button("Cancel Install", role: .destructive) {
                        installTask?.cancel()
                        localLibrary.cancelInstall()
                    }
                }
            }
            ToolbarItem {
                Button {
                    showingPlaylist = true
                } label: {
                    Label("Playlist", systemImage: "music.note.list")
                }
                .help("Show the local HVSC playlist")
            }
            ToolbarItem {
                Button {
                    Stream64ToolWindows.showSIDRadio()
                } label: {
                    Label("SID Station", systemImage: "dot.radiowaves.left.and.right")
                }
                .help("Open SID Station")
            }
        }
        .confirmationDialog(
            "Install HVSC Update?",
            isPresented: $showingUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Install Compatible Update") {
                guard let destination = pendingUpdateDestination else { return }
                pendingUpdateDestination = nil
                installTask = Task {
                    await localLibrary.install(from: destination, update: true)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingUpdateDestination = nil
            }
        } message: {
            Text("Stream64 will update the compatible local HVSC installation in the selected folder.")
        }
        .task {
            localLibrary.refreshAvailability()
            await localLibrary.fetchManifest()
        }
        .sheet(isPresented: $showingPlaylist) { playlistSheet }
        .frame(minWidth: 880, minHeight: 560)
    }

    private var configurationView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            Image(systemName: "externaldrive")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Choose Your Extracted\nHVSC Folder")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(configurationText)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            HStack {
            Button("Choose HVSC Folder…") { presentFolderPicker(forInstall: false) }
                if localLibrary.manifest != nil {
                    Button("Install Full HVSC…") {
                        installUpdate = false
                    presentFolderPicker(forInstall: true)
                    }
                }
            }
            if case let .failed(message) = localLibrary.status {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            installProgress
                .frame(width: 420, alignment: .leading)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var configurationText: String {
        switch localLibrary.status {
            case .indexing:
                if let progress = localLibrary.indexProgress {
                    return "Indexed \(progress.indexedTunes) valid SID headers from \(progress.discoveredSIDFiles) SID files…"
                }
                return "Indexing SID headers and paths locally…"
        case .failed(let message): return message
        default:
            return "If you already downloaded HVSC, choose its C64Music folder — not the enclosing download folder. Stream64 checks that MUSICIANS and DOCUMENTS are present before indexing SID metadata locally."
        }
    }

    private func presentFolderPicker(forInstall: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = forInstall ? "Use This Folder" : "Choose C64Music"
        panel.message = forInstall
            ? "Choose the folder where Stream64 should create C64Music."
            : "Choose the extracted C64Music folder."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if forInstall {
                if installUpdate {
                    pendingUpdateDestination = url
                    showingUpdateConfirmation = true
                } else {
                    installTask = Task {
                        await localLibrary.install(from: url, update: false)
                    }
                }
            } else {
                localLibrary.chooseRoot(url)
            }
        }
    }

    private var browser: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("Collection", selection: $collection) {
                    ForEach(HVSCClient.SearchFilters.Collection.allCases) { collection in
                        Text(collection.label).tag(collection)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top], 10)
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   collection == .all {
                    folderBrowser
                } else {
                    Table(sortedResults, selection: $selection, sortOrder: $sortOrder) {
                        TableColumn("Title", value: \.title)
                        TableColumn("Author", value: \.author)
                        TableColumn("Release", value: \.released)
                        TableColumn("Path", value: \.relativePath)
                    }
                    .onChange(of: selection) { _, _ in
                        guard let tune = selectedTune else { return }
                        // NSTableView is still inside its selection delegate
                        // here. Mutating the split-view detail state directly
                        // re-enters that delegate on current AppKit.
                        DispatchQueue.main.async {
                            status = tune.relativePath
                        }
                    }
                    .background(
                        HVSCResultTableDoubleClickHandler { row in
                            guard sortedResults.indices.contains(row) else {
                                return
                            }
                            selectAndPlay(sortedResults[row])
                        })
                }
                footer
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            detail
                .frame(minWidth: 320, idealWidth: 360, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !browsePath.isEmpty {
                    Button {
                        browsePath = String(
                            browsePath.split(separator: "/").dropLast()
                                .joined(separator: "/"))
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .help("Browse the parent HVSC folder")
                }
                Text(browsePath.isEmpty ? "Browse HVSC" : browsePath)
                    .font(.headline)
                Spacer()
            }
            .padding(12)

            let folders = localLibrary.folders(at: browsePath)
            if folders.isEmpty && results.isEmpty {
                ContentUnavailableView(
                    "No Tunes in This Folder",
                    systemImage: "folder",
                    description: Text("Choose another folder or search the local library."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(folders, id: \.self) { folder in
                        Button {
                            browsePath = browsePath.isEmpty
                                ? folder : "\(browsePath)/\(folder)"
                        } label: {
                            Label(folder, systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(sortedResults) { tune in
                        let isSelected = selection == tune.id
                        Button {
                            selection = tune.id
                        } label: {
                            Label(tune.filename, systemImage: "music.note")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 5)
                                .background(
                                    isSelected
                                        ? Color.gray.opacity(0.20)
                                        : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .onTapGesture(count: 2) {
                            selectAndPlay(tune)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            switch localLibrary.status {
            case .ready(let count): Text("\(results.count) of \(count) local tunes")
            case .indexing:
                if let progress = localLibrary.indexProgress {
                    ProgressView("Indexed \(progress.indexedTunes) headers (\(progress.discoveredSIDFiles) SID files)")
                } else {
                    ProgressView("Indexing…")
                }
            case .failed(let message): Text(message)
            case .unconfigured: EmptyView()
            }
            Spacer()
            if let manifest = localLibrary.manifest {
                Text("HVSC #\(manifest.version)")
            }
        }
        .font(.callout).foregroundStyle(.secondary).padding(10)
        .overlay(alignment: .bottomLeading) { installProgress }
    }

    @ViewBuilder
    private var installProgress: some View {
        if let message = localLibrary.installStatus {
            VStack(alignment: .leading, spacing: 4) {
                if let phase = localLibrary.installPhase {
                    Text(phase).font(.caption.weight(.semibold))
                }
                if let progress = localLibrary.installProgress {
                    ProgressView(message, value: progress)
                } else if localLibrary.isInstalling {
                    ProgressView(message)
                } else {
                    Text(message)
                }
                if let progress = localLibrary.downloadProgress {
                    Text(downloadSummary(progress))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    private func downloadSummary(_ progress: HVSCDownloadProgress) -> String {
        let downloaded = ByteCountFormatter.string(
            fromByteCount: progress.bytesDownloaded, countStyle: .file)
        let size: String
        if let total = progress.totalBytes {
            size = "\(downloaded) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        } else {
            size = "\(downloaded) downloaded"
        }
        let rate = ByteCountFormatter.string(
            fromByteCount: Int64(progress.bytesPerSecond), countStyle: .file) + "/s"
        let remaining: String
        if let eta = progress.estimatedTimeRemaining {
            remaining = " · \(Duration.seconds(eta).formatted(.time(pattern: .minuteSecond))) remaining"
        } else if progress.totalBytes == nil {
            remaining = " · time remaining unknown"
        } else {
            remaining = ""
        }
        return "\(size) · \(rate)\(remaining)"
    }

    private var updateHelp: String {
        guard localLibrary.manifest != nil else {
            return "Checking the latest HVSC release…"
        }
        return localLibrary.canInstallUpdate
            ? "Install the compatible update after confirmation"
            : "No compatible update is available for this Stream64-managed HVSC installation"
    }

    @ViewBuilder
    private var detail: some View {
        if let tune = selectedTune {
            VStack(alignment: .leading, spacing: 10) {
                Text(tune.title).font(.title3.weight(.semibold))
                Label(tune.author.isEmpty ? "Unknown author" : tune.author, systemImage: "person")
                Label(tune.released.isEmpty ? "Unknown release" : tune.released, systemImage: "calendar")
                Divider()
                LabeledContent("Path", value: tune.relativePath)
                LabeledContent("Format", value: tune.format)
                LabeledContent("Songs", value: "\(tune.songs) (starts \(tune.startSong))")
                LabeledContent("SID", value: tune.sidRequirements)
                if let durations = durations(for: tune) {
                    Text("Song lengths").font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(durations.prefix(16).enumerated()), id: \.offset) { index, duration in
                                Text("Song \(index + 1): \(duration / 60_000):\(String(format: "%02d", duration / 1_000 % 60))")
                                    .font(.callout)
                            }
                            if durations.count > 16 {
                                Text("\(durations.count - 16) more subtunes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
                Spacer()
                Button("Play on \(target?.name ?? "Selected C64")", systemImage: "play.fill") {
                    play(tune)
                }
                .disabled(playing || target == nil)
                Button {
                    localLibrary.addToPlaylist(tune)
                } label: {
                    Label(
                        localLibrary.playlist.contains(where: {
                            $0.relativePath.caseInsensitiveCompare(tune.relativePath)
                                == .orderedSame
                        }) ? "In Local Playlist" : "Add to Local Playlist",
                        systemImage: "text.badge.plus")
                }
                .disabled(localLibrary.playlist.contains(where: {
                    $0.relativePath.caseInsensitiveCompare(tune.relativePath)
                        == .orderedSame
                }))
                let stationKey = SIDFlowTrackKey(
                    sidPath: tune.relativePath, songIndex: tune.startSong)
                let isLiked = recommendations.likedKeys.contains(stationKey)
                Button {
                    recommendations.like(stationKey)
                } label: {
                    Label(
                        isLiked ? "Liked for SID Station" : "Like for SID Station",
                        systemImage: isLiked ? "heart.fill" : "heart")
                }
                .foregroundStyle(isLiked ? .red : .primary)
                .help(isLiked
                    ? "This tune is in your SID Station likes"
                    : "Add this tune to your SID Station likes")
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(14)
        } else {
            ContentUnavailableView("No Tune Selected", systemImage: "music.note.list",
                                   description: Text("Select a local SID to inspect and play it."))
        }
    }

    private func durations(for tune: LocalHVSCTune) -> [Int]? {
        guard let data = try? localLibrary.data(for: tune) else { return nil }
        return songlengths.durations(for: data)
    }

    private func play(_ tune: LocalHVSCTune) {
        guard let device = target else { return }
        playing = true
        status = "Loading \(tune.filename)…"
        Task {
            defer { playing = false }
            do {
                let data = try localLibrary.data(for: tune)
                _ = try SIDHeader(data: data)
                let loaded = await sessionProvider(device).loadData(data, filename: tune.filename,
                                                                    songNumber: tune.startSong)
                status = loaded == nil ? "The Ultimate did not accept \(tune.filename)." : "Playing \(tune.filename)."
            } catch {
                status = "Play failed: \(error.localizedDescription)"
            }
        }
    }

    private func selectAndPlay(_ tune: LocalHVSCTune) {
        // Let AppKit complete its selection callback before starting network
        // playback; changing detail state inside that callback re-enters
        // NSTableView on current macOS releases.
        selection = tune.id
        status = tune.relativePath
        DispatchQueue.main.async {
            play(tune)
        }
    }

    private var playlistSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Local HVSC Playlist").font(.headline)
                Spacer()
                Button("Clear", role: .destructive) {
                    localLibrary.clearPlaylist()
                    playlistSelection = nil
                    playlistPlaybackIndex = nil
                }
                .disabled(localLibrary.playlist.isEmpty)
                Button("Done") { showingPlaylist = false }
            }
            .padding()
            if localLibrary.playlist.isEmpty {
                ContentUnavailableView(
                    "Playlist Is Empty",
                    systemImage: "music.note.list",
                    description: Text("Add tunes from the HVSC browser to play them in order in SID Station."))
            } else {
                List(localLibrary.playlist) { entry in
                    let tune = localLibrary.tune(for: entry)
                    let isSelected = playlistSelection == entry.id
                    HStack(spacing: 10) {
                        Image(systemName: tune == nil ? "music.note.slash" : "music.note")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tune?.title ?? entry.relativePath)
                                .lineLimit(1)
                            Text(entry.relativePath)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            localLibrary.movePlaylistEntry(
                                from: localLibrary.playlist.firstIndex(of: entry) ?? 0,
                                by: -1)
                        } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderless)
                        .disabled(localLibrary.playlist.first?.id == entry.id)
                        Button {
                            localLibrary.movePlaylistEntry(
                                from: localLibrary.playlist.firstIndex(of: entry) ?? 0,
                                by: 1)
                        } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.borderless)
                        .disabled(localLibrary.playlist.last?.id == entry.id)
                        Button {
                            localLibrary.removeFromPlaylist(entry)
                            if playlistSelection == entry.id { playlistSelection = nil }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { playlistSelection = entry.id }
                    // Keep selection deliberately muted; unavailable paths
                    // should not look playable merely because they are selected.
                    .foregroundStyle(tune == nil ? .secondary : .primary)
                    .background(isSelected ? Color.gray.opacity(0.18) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button {
                    playPlaylist(at: playlistPlaybackIndex ?? 0)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(localLibrary.playlist.isEmpty || target == nil)
                Button { previousPlaylist() } label: {
                    Image(systemName: "backward.fill")
                }
                .disabled(playlistPlaybackIndex == nil)
                Button { nextPlaylist() } label: {
                    Image(systemName: "forward.fill")
                }
                .disabled(localLibrary.playlist.isEmpty)
                Button { playlistShuffle.toggle() } label: {
                    Image(systemName: "shuffle")
                }
                .foregroundStyle(playlistShuffle ? Color.accentColor : Color.primary)
                Button { playlistLoop.toggle() } label: {
                    Image(systemName: "repeat")
                }
                .foregroundStyle(playlistLoop ? Color.accentColor : Color.primary)
                Spacer()
                if let index = playlistPlaybackIndex,
                   localLibrary.playlist.indices.contains(index) {
                    Text("Now: \(localLibrary.playlist[index].relativePath)")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(width: 620, height: 440)
        .onDisappear { stopPlaylistPlayback() }
    }

    private func playPlaylist(at requestedIndex: Int) {
        guard let device = target, !localLibrary.playlist.isEmpty else { return }
        playlistPlaybackTask?.cancel()
        playlistPlaybackTask = Task {
            var index = requestedIndex
            while !Task.isCancelled {
                if playlistShuffle {
                    index = localLibrary.playlist.indices.randomElement() ?? 0
                }
                guard localLibrary.playlist.indices.contains(index) else {
                    if playlistLoop {
                        index = 0
                        continue
                    }
                    playlistPlaybackIndex = nil
                    playlistPlaybackTask = nil
                    return
                }
                let entry = localLibrary.playlist[index]
                playlistPlaybackIndex = index
                playlistSelection = entry.id
                guard let tune = localLibrary.tune(for: entry) else {
                    status = "Skipped unavailable playlist entry: \(entry.relativePath)"
                    index += 1
                    continue
                }
                do {
                    playing = true
                    status = "Loading \(tune.filename)…"
                    let session = sessionProvider(device)
                    let data = try localLibrary.data(for: tune)
                    let header = try SIDHeader(data: data)
                    guard !Task.isCancelled,
                          await session.loadData(
                            data, filename: tune.filename,
                            songNumber: tune.startSong) != nil else {
                        playing = false
                        index += 1
                        continue
                    }
                    let duration = songlengths.durations(for: data)?
                        .dropFirst(max(0, tune.startSong - 1)).first
                        ?? Int(settings.sidRadioFallbackDurationSeconds * 1_000)
                    status = "Playing \(header.title.isEmpty ? tune.filename : header.title)"
                    await fadeOut(
                        session: session, durationMilliseconds: duration)
                    guard !Task.isCancelled else { return }
                    session.audioReceiver.volume = Float(settings.volume)
                    index += 1
                } catch {
                    status = "Skipped \(tune.filename): \(error.localizedDescription)"
                    index += 1
                }
                playing = false
            }
        }
    }

    private func nextPlaylist() {
        guard !localLibrary.playlist.isEmpty else { return }
        let next = (playlistPlaybackIndex ?? -1) + 1
        if localLibrary.playlist.indices.contains(next) {
            playPlaylist(at: next)
        } else if playlistLoop {
            playPlaylist(at: 0)
        } else {
            playlistPlaybackIndex = nil
        }
    }

    private func previousPlaylist() {
        guard let playlistPlaybackIndex else { return }
        playPlaylist(at: max(0, playlistPlaybackIndex - 1))
    }

    private func stopPlaylistPlayback() {
        playlistPlaybackTask?.cancel()
        playlistPlaybackTask = nil
        playing = false
        if let target {
            sessionProvider(target).audioReceiver.volume = Float(settings.volume)
        }
    }

    private func fadeOut(
        session: DeviceSession,
        durationMilliseconds: Int
    ) async {
        guard settings.sidRadioFadeOutEnabled else {
            try? await Task.sleep(for: .milliseconds(durationMilliseconds))
            return
        }
        let fadeMilliseconds = min(3_000, max(0, durationMilliseconds))
        let leadMilliseconds = max(0, durationMilliseconds - fadeMilliseconds)
        if leadMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(leadMilliseconds))
        }
        guard !Task.isCancelled, fadeMilliseconds > 0 else { return }
        let initialVolume = Float(settings.volume)
        for step in 1...20 where !Task.isCancelled {
            session.audioReceiver.volume = initialVolume * Float(20 - step) / 20
            try? await Task.sleep(
                for: .milliseconds(max(1, fadeMilliseconds / 20)))
        }
    }
}

private struct HVSCResultTableDoubleClickHandler: NSViewRepresentable {
    let onDoubleClick: (Int) -> Void

    func makeNSView(context: Context) -> HVSCResultTableDoubleClickView {
        let view = HVSCResultTableDoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: HVSCResultTableDoubleClickView, context: Context) {
        view.onDoubleClick = onDoubleClick
    }
}

private final class HVSCResultTableDoubleClickView: NSView {
    var onDoubleClick: ((Int) -> Void)?
    private weak var tableView: NSTableView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToTableView()
    }

    private func attachToTableView() {
        guard tableView == nil else { return }
        var current: NSView? = self
        while let view = current {
            if let table = view as? NSTableView {
                tableView = table
                table.target = self
                table.doubleAction = #selector(handleDoubleClick(_:))
                return
            }
            current = view.superview
        }
    }

    @objc private func handleDoubleClick(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onDoubleClick?(row)
        }
    }
}
