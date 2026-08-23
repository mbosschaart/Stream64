import AppKit
import SwiftUI

/// A native, on-demand player for recommendations from the separately
/// published SIDFlow data bundle. It never owns a SID-file cache: the selected
/// tune is resolved from HVSC and immediately sent to the Ultimate.
struct SIDRadioView: View {
    private enum PlaybackMode: String, CaseIterable, Identifiable {
        case station = "Station"
        case playlist = "Playlist"

        var id: Self { self }
    }

    @EnvironmentObject private var deviceStore: DeviceStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SIDFlowRecommendationStore
    @EnvironmentObject private var library: HVSCLibraryStore
    @EnvironmentObject private var localLibrary: HVSCLocalLibrary

    let sessionProvider: (UltimateDevice) -> DeviceSession
    private let fadeOutDurationMilliseconds = 3_000

    @State private var queue: [SIDFlowRecommendation] = []
    @State private var currentIndex: Int?
    @State private var advanceTask: Task<Void, Never>?
    @State private var refillTask: Task<Void, Never>?
    @State private var shuffle = false
    @State private var loop = false
    @State private var isPlaying = false
    @State private var isLoadingTrack = false
    @State private var isPaused = false
    @State private var playbackStatus: String?
    @State private var nowPlayingHeader: SIDHeader?
    @State private var nowPlayingDurationMilliseconds: Int?
    @State private var nowPlayingUsesFallbackDuration = false
    @State private var showingHistory = false
    @State private var playbackMode: PlaybackMode = .station
    @State private var playlistCurrentIndex: Int?
    @State private var playlistTask: Task<Void, Never>?
    @State private var playlistIsLoading = false

    private var targetDevice: UltimateDevice? { deviceStore.selectedDevice }
    private var targetLabel: String { targetDevice?.name ?? "No Selected C64" }

    var body: some View {
        Group {
            if !localLibrary.isReady {
                ContentUnavailableView(
                    "SID Station Needs HVSC Data",
                    systemImage: "externaldrive",
                    description: Text("Choose and index an extracted HVSC folder in the HVSC Browser window before starting SID Station."))
            } else {
                VStack(spacing: 0) {
                    Picker("Playback Mode", selection: $playbackMode) {
                        ForEach(PlaybackMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    if playbackMode == .station {
                        stationContent
                    } else {
                        playlistContent
                    }
                }
            }
        }
        .navigationTitle("SID Station")
        .toolbar { toolbar }
        .task {
            if queue.isEmpty {
                queue = Array(store.recommendations.prefix(settings.sidRadioQueueSize))
            }
        }
        .onDisappear { stop() }
        .sheet(isPresented: $showingHistory) { historySheet }
        .frame(minWidth: 760, minHeight: 500)
    }

    @ViewBuilder
    private var stationContent: some View {
        if !store.isInstalled {
            ContentUnavailableView {
                Label("SID Station Needs Recommendation Data", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("A random-playing station built from your local HVSC likes. It uses verified SIDFlow similarity data; SID files stay in your selected local corpus.")
            } actions: {
                Button("Download Recommendation Data") {
                    Task { await store.downloadLatest() }
                }
                .disabled(store.isLoading)
                Link(
                    "View SIDFlow data release",
                    destination: URL(string: "https://github.com/chrisgleissner/sidflow-data/releases")!)
                Text(store.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            recommendationsList
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem { Text(targetLabel).foregroundStyle(.secondary) }
        if localLibrary.isReady {
            ToolbarItem {
                Button {
                    Task { await store.downloadLatest() }
                } label: {
                    Label("Update Data", systemImage: "arrow.down.circle")
                }
                .disabled(store.isLoading)
                .help("Download the latest recommendation data")
            }
            ToolbarItem {
                Button {
                    showingHistory = true
                } label: {
                    Label("Playback History", systemImage: "clock.arrow.circlepath")
                }
                .help("Show SID Station playback history")
            }
        }
    }

    private var recommendationsList: some View {
        VStack(spacing: 0) {
            if store.likedKeys.isEmpty {
                ContentUnavailableView(
                    "Like an HVSC Tune First",
                    systemImage: "heart",
                    description: Text("In the HVSC Browser, select a tune and choose “Like for SID Station.”"))
            } else if queue.isEmpty {
                ContentUnavailableView(
                    "No More Recommendations",
                    systemImage: "music.note.slash",
                    description: Text("Skipped and recently played tunes are excluded. Like another HVSC tune to widen the station."))
            } else {
                if !upNextRecommendations.isEmpty {
                    HStack {
                        Label("Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.headline)
                        Text(upNextRecommendations.map(\.key.filename).joined(separator: " · "))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                List(Array(queue.enumerated()), id: \.element.id) { _, recommendation in
                    let isLiked = store.likedKeys.contains(recommendation.key)
                    let localTune = localLibrary.tunes.first {
                        $0.relativePath.caseInsensitiveCompare(
                            recommendation.key.sidPath) == .orderedSame
                    }
                    let isInPlaylist = localTune.map { tune in
                        localLibrary.playlist.contains { entry in
                            entry.relativePath.caseInsensitiveCompare(
                                tune.relativePath) == .orderedSame
                        }
                    } ?? false
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recommendation.key.filename)
                                .font(.headline)
                                .lineLimit(1)
                            Text(recommendation.key.sidPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(recommendation.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.like(recommendation.key)
                        } label: {
                            Image(systemName: isLiked ? "heart.fill" : "heart")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(isLiked ? .red : .primary)
                        .help(isLiked
                            ? "This tune is in your SID Station likes"
                            : "Like this tune")
                        Button {
                            store.skip(recommendation.key)
                        } label: {
                            Image(systemName: "forward.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Skip this tune")
                        Button {
                            playNext(recommendation)
                        } label: {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        }
                        .buttonStyle(.borderless)
                        .help("Play next")
                        Button {
                            removeFromQueue(recommendation)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from queue")
                        if let localTune {
                            Button {
                                localLibrary.addToPlaylist(localTune)
                            } label: {
                                Image(systemName: isInPlaylist
                                    ? "text.badge.checkmark"
                                    : "text.badge.plus")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(
                                isInPlaylist ? Color.accentColor : Color.primary)
                            .disabled(isInPlaylist)
                            .help(isInPlaylist
                                ? "This tune is already in the local playlist"
                                : "Add this tune to the local playlist")
                        }
                        Button(currentRecommendation?.id == recommendation.id ? "Playing" : "Play") {
                            start(at: recommendation)
                        }
                        .disabled(isLoadingTrack || targetDevice == nil)
                    }
                    .padding(.vertical, 3)
                }
                .background(
                    ScrollEndNudgeDetector { scheduleQueueRefill() })
                if refillTask != nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finding the next tune…")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            Divider()
            transport
            Divider()
            HStack {
                if isLoadingTrack { ProgressView().controlSize(.small) }
                Text(playbackStatus ?? store.status)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if let manifest = store.manifest {
                    Text(manifest.hvscVersion ?? manifest.corpusVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Link(
                    "More like this: SIDFlow data by Chris Gleissner",
                    destination: URL(string: "https://github.com/chrisgleissner/sidflow")!)
                    .font(.caption)
            }
            .font(.callout)
            .padding(12)
        }
    }

    private var playlistContent: some View {
        VStack(spacing: 0) {
            if localLibrary.playlist.isEmpty {
                ContentUnavailableView(
                    "Local Playlist Is Empty",
                    systemImage: "music.note.list",
                    description: Text("Add tunes in the HVSC Browser, then play them here in their saved order."))
            } else {
                List(Array(localLibrary.playlist.enumerated()), id: \.element.id) { index, entry in
                    let tune = localLibrary.tune(for: entry)
                    let isCurrent = playlistCurrentIndex == index
                    Button {
                        startPlaylist(at: index)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tune == nil ? "music.note.slash" : "music.note")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tune?.title ?? entry.relativePath)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(entry.relativePath)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if isCurrent {
                                Text(playlistIsLoading ? "Loading" : "Playing")
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(tune == nil || playlistIsLoading || targetDevice == nil)
                    .foregroundStyle(tune == nil ? .secondary : .primary)
                    // A selected unavailable row remains visibly muted rather
                    // than taking on the normal actionable accent treatment.
                    .listRowBackground(
                        isCurrent ? Color.gray.opacity(0.18) : Color.clear)
                }
            }
            Divider()
            playlistTransport
            Divider()
            HStack {
                if playlistIsLoading { ProgressView().controlSize(.small) }
                Text(playbackStatus ?? "Plays the local playlist in saved order.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .font(.callout)
            .padding(12)
        }
    }

    private var historySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SID Station History").font(.headline)
                Spacer()
                Button("Clear", role: .destructive) {
                    store.clearHistory()
                }
                .disabled(store.history.isEmpty)
            }
            .padding()
            if store.history.isEmpty {
                ContentUnavailableView(
                    "No Playback History",
                    systemImage: "clock",
                    description: Text("Played SID Station tracks appear here."))
            } else {
                List(store.history) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.key.filename)
                            Text(entry.completion.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Replay") {
                            if let recommendation = queue.first(where: {
                                $0.key == entry.key
                            }) {
                                start(at: recommendation)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(width: 460, height: 420)
    }

    private var playlistTransport: some View {
        HStack(spacing: 12) {
            Button {
                if playlistCurrentIndex == nil {
                    startPlaylist(at: 0)
                } else {
                    startPlaylist(at: playlistCurrentIndex!)
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(localLibrary.playlist.isEmpty || targetDevice == nil)
            Button { previousPlaylist() } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(playlistCurrentIndex == nil)
            Button { nextPlaylist() } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(localLibrary.playlist.isEmpty)
            Button { loop.toggle() } label: { Image(systemName: "repeat") }
                .foregroundStyle(loop ? Color.accentColor : Color.primary)
                .help(loop ? "Disable playlist loop" : "Loop the playlist")
            Button { stopPlaylist() } label: { Image(systemName: "stop.fill") }
                .disabled(playlistTask == nil)
            Spacer()
            if let entry = playlistCurrentIndex.flatMap({
                localLibrary.playlist.indices.contains($0) ? localLibrary.playlist[$0] : nil
            }) {
                Text("Now: \(localLibrary.tune(for: entry)?.filename ?? entry.relativePath)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var currentRecommendation: SIDFlowRecommendation? {
        currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil }
    }

    private var upNextRecommendations: [SIDFlowRecommendation] {
        guard let currentIndex else {
            return Array(queue.prefix(settings.sidRadioQueueSize))
        }
        let start = queue.index(after: currentIndex)
        guard start < queue.endIndex else { return [] }
        return Array(queue[start...].prefix(settings.sidRadioQueueSize))
    }

    private var nowPlayingTitle: String {
        guard let currentRecommendation else { return "" }
        let title = nowPlayingHeader?.title.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? currentRecommendation.key.filename : title
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { currentIndex == nil ? start(at: queue.first) : resume() } label: {
                Label(isPaused ? "Resume" : "Play", systemImage: isPaused ? "play.fill" : "play.fill")
            }
            .disabled(queue.isEmpty || targetDevice == nil)
            .help(isPaused ? "Resume playback" : "Play the selected station queue")
            Button { previous() } label: { Image(systemName: "backward.fill") }
                .disabled(currentIndex == nil)
                .help("Play the previous tune")
            Button { next() } label: { Image(systemName: "forward.fill") }
                .disabled(queue.isEmpty)
                .help("Play the next tune")
            Button { shuffle.toggle() } label: { Image(systemName: "shuffle") }
                .foregroundStyle(shuffle ? Color.accentColor : Color.primary)
                .help(shuffle ? "Disable shuffle" : "Enable shuffle")
            Button { loop.toggle() } label: { Image(systemName: "repeat") }
                .foregroundStyle(loop ? Color.accentColor : Color.primary)
                .help(loop ? "Disable loop" : "Enable loop")
            Button { pause() } label: { Image(systemName: "pause.fill") }
                .disabled(!isPlaying || isPaused)
                .help("Pause playback")
            Spacer()
            if let currentRecommendation {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Now: \(nowPlayingTitle)")
                        .lineLimit(1)
                    if let nowPlayingHeader {
                        Text(metadataLine(for: nowPlayingHeader))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Button {
                    store.like(currentRecommendation.key)
                    playbackStatus = "Liked \(currentRecommendation.key.filename)."
                } label: {
                    Image(systemName: "heart.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(
                    store.likedKeys.contains(currentRecommendation.key)
                        ? Color.red : Color.secondary)
                .help("Like the current tune")
                Button {
                    store.skip(currentRecommendation.key)
                    store.finishPlaying(
                        currentRecommendation.key,
                        listenedMilliseconds: 0,
                        completion: .skipped)
                    playbackStatus = "Disliked \(currentRecommendation.key.filename)."
                    next()
                } label: {
                    Image(systemName: "hand.thumbsdown.fill")
                }
                .buttonStyle(.borderless)
                .help("Dislike the current tune and play the next one")
            }
        }
        .padding(12)
    }

    private func start(at recommendation: SIDFlowRecommendation?) {
        guard let recommendation, let index = queue.firstIndex(of: recommendation),
              let device = targetDevice else { return }
        currentIndex = index
        advanceTask?.cancel()
        isPlaying = true
        isLoadingTrack = true
        isPaused = false
        playbackStatus = "Loading \(recommendation.key.filename) from local HVSC…"
        advanceTask = Task {
            defer { isPlaying = false }
            let session = sessionProvider(device)
            do {
                guard let tune = localLibrary.tunes.first(where: {
                    $0.relativePath.caseInsensitiveCompare(recommendation.key.sidPath) == .orderedSame
                }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let sid = try localLibrary.data(for: tune)
                let header = try SIDHeader(data: sid)
                guard !Task.isCancelled else { return }
                nowPlayingHeader = header
                guard !Task.isCancelled,
                      await session.loadData(
                        sid, filename: recommendation.key.filename,
                        songNumber: recommendation.key.songIndex,
                        onUploadStarted: {
                            // The preceding SID can leave a few residual
                            // stream packets. Let the Ultimate begin handling
                            // the new upload, then restore output shortly after.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(150))
                                session.audioReceiver.volume = Float(settings.volume)
                            }
                        }) != nil else {
                    session.audioReceiver.volume = Float(settings.volume)
                    isLoadingTrack = false
                    playbackStatus = "The Ultimate did not accept \(recommendation.key.filename)."
                    return
                }
                isLoadingTrack = false
                store.recordPlayed(recommendation.key)
                // Start ranking the successor while the final visible tune is
                // still playing. `next()` remains after `fadeOut`, so this
                // cannot cut the current tune short.
                if index == queue.index(before: queue.endIndex) {
                    scheduleQueueRefill()
                }
                let duration = library.durations(for: sid)?
                    .dropFirst(max(0, recommendation.key.songIndex - 1)).first
                    .map(Double.init)
                    ?? settings.sidRadioFallbackDurationSeconds * 1_000
                nowPlayingDurationMilliseconds = Int(duration)
                nowPlayingUsesFallbackDuration = library.durations(for: sid)?
                    .dropFirst(max(0, recommendation.key.songIndex - 1)).first == nil
                playbackStatus = "Playing \(recommendation.key.filename)."
                await fadeOut(
                    session: session,
                    totalDurationMilliseconds: Int(duration))
                guard !Task.isCancelled else { return }
                store.finishPlaying(
                    recommendation.key,
                    listenedMilliseconds: Int(duration),
                    completion: .completed)
                next()
            } catch {
                session.audioReceiver.volume = Float(settings.volume)
                isLoadingTrack = false
                playbackStatus = "Play failed: \(error.localizedDescription)"
                next()
            }
        }
    }

    private func startPlaylist(at requestedIndex: Int) {
        guard let device = targetDevice else { return }
        playlistTask?.cancel()
        playlistTask = Task {
            var index = requestedIndex
            while !Task.isCancelled {
                guard localLibrary.playlist.indices.contains(index) else {
                    if loop, !localLibrary.playlist.isEmpty {
                        index = 0
                    } else {
                        playlistCurrentIndex = nil
                        playlistIsLoading = false
                        playbackStatus = "Reached the end of the local playlist."
                        playlistTask = nil
                        return
                    }
                    continue
                }
                playlistCurrentIndex = index
                let entry = localLibrary.playlist[index]
                guard let tune = localLibrary.tune(for: entry) else {
                    playbackStatus = "Skipped unavailable playlist entry: \(entry.relativePath)"
                    index += 1
                    continue
                }
                playlistIsLoading = true
                playbackStatus = "Loading \(tune.filename) from local HVSC…"
                let session = sessionProvider(device)
                do {
                    let sid = try localLibrary.data(for: tune)
                    let header = try SIDHeader(data: sid)
                    guard !Task.isCancelled else { return }
                    nowPlayingHeader = header
                    guard await session.loadData(
                        sid, filename: tune.filename, songNumber: tune.startSong,
                        onUploadStarted: {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(150))
                                session.audioReceiver.volume = Float(settings.volume)
                            }
                        }) != nil else {
                        playbackStatus = "The Ultimate did not accept \(tune.filename); skipped."
                        index += 1
                        continue
                    }
                    playlistIsLoading = false
                    let duration = library.durations(for: sid)?
                        .dropFirst(max(0, tune.startSong - 1)).first
                        .map(Double.init)
                        ?? settings.sidRadioFallbackDurationSeconds * 1_000
                    nowPlayingDurationMilliseconds = Int(duration)
                    nowPlayingUsesFallbackDuration = library.durations(for: sid)?
                        .dropFirst(max(0, tune.startSong - 1)).first == nil
                    playbackStatus = "Playing \(tune.filename)."
                    await fadeOut(
                        session: session, totalDurationMilliseconds: Int(duration))
                    guard !Task.isCancelled else { return }
                    session.audioReceiver.volume = Float(settings.volume)
                    index += 1
                } catch {
                    session.audioReceiver.volume = Float(settings.volume)
                    playlistIsLoading = false
                    playbackStatus = "Skipped \(tune.filename): \(error.localizedDescription)"
                    index += 1
                }
            }
        }
    }

    private func nextPlaylist() {
        let next = (playlistCurrentIndex ?? -1) + 1
        if localLibrary.playlist.indices.contains(next) {
            startPlaylist(at: next)
        } else if loop {
            startPlaylist(at: 0)
        } else {
            stopPlaylist()
            playbackStatus = "Reached the end of the local playlist."
        }
    }

    private func previousPlaylist() {
        guard let playlistCurrentIndex else { return }
        startPlaylist(at: max(0, playlistCurrentIndex - 1))
    }

    private func stopPlaylist() {
        playlistTask?.cancel()
        playlistTask = nil
        playlistIsLoading = false
        if let device = targetDevice {
            sessionProvider(device).audioReceiver.volume = Float(settings.volume)
        }
    }

    private func next() {
        advanceTask?.cancel()
        guard !queue.isEmpty else { return }
        var index = (currentIndex ?? -1) + 1
        if shuffle { index = queue.indices.randomElement() ?? 0 }
        if index >= queue.count {
            fetchNextTuneAtQueueEnd()
            return
        }
        start(at: queue[index])
    }

    private func playNext(_ recommendation: SIDFlowRecommendation) {
        guard let from = queue.firstIndex(of: recommendation) else { return }
        let item = queue.remove(at: from)
        let destination = min(
            queue.count, (currentIndex.map { $0 + 1 } ?? 0))
        queue.insert(item, at: destination)
        if let currentIndex, from < currentIndex {
            self.currentIndex = max(0, currentIndex - 1)
        }
    }

    private func removeFromQueue(_ recommendation: SIDFlowRecommendation) {
        guard let index = queue.firstIndex(of: recommendation) else { return }
        if index == currentIndex {
            next()
        }
        queue.removeAll { $0.id == recommendation.id }
        if let currentIndex, index < currentIndex {
            self.currentIndex = currentIndex - 1
        }
    }

    /// Adds one unseen recommendation when the user reaches the final row,
    /// keeping the station list continuous without growing it in bulk.
    private func scheduleQueueRefill() {
        guard refillTask == nil else { return }
        let queuedKeys = Set(queue.map(\.key))
        refillTask = Task {
            let additions = await store.freshRecommendations(
                excluding: queuedKeys, limit: 1,
                diversity: settings.sidRadioDiversity,
                pathCooldown: settings.sidRadioPathCooldown)
            guard !Task.isCancelled else {
                refillTask = nil
                return
            }
            queue.append(contentsOf: additions)
            refillTask = nil
        }
    }

    private func fetchNextTuneAtQueueEnd() {
        scheduleQueueRefill()
        guard let refillTask else {
            currentIndex = nil
            return
        }
        advanceTask = Task {
            await refillTask.value
            guard !Task.isCancelled else { return }
            if let index = currentIndex.map({ $0 + 1 }),
               queue.indices.contains(index) {
                start(at: queue[index])
            } else if loop, let first = queue.first {
                start(at: first)
            } else {
                currentIndex = nil
            }
        }
    }

    private func previous() {
        guard let currentIndex else { return }
        start(at: queue[max(0, currentIndex - 1)])
    }

    private func pause() {
        advanceTask?.cancel()
        isPaused = true
        isPlaying = false
    }

    private func resume() {
        guard let currentRecommendation else { return }
        start(at: currentRecommendation)
    }

    private func stop() {
        advanceTask?.cancel()
        advanceTask = nil
        stopPlaylist()
        isLoadingTrack = false
        if let device = targetDevice {
            sessionProvider(device).audioReceiver.volume = Float(settings.volume)
        }
    }

    private func fadeOut(
        session: DeviceSession,
        totalDurationMilliseconds: Int
    ) async {
        guard settings.sidRadioFadeOutEnabled else {
            try? await Task.sleep(for: .milliseconds(totalDurationMilliseconds))
            return
        }
        let fadeMilliseconds = min(
            fadeOutDurationMilliseconds,
            max(0, totalDurationMilliseconds))
        let leadMilliseconds = max(0, totalDurationMilliseconds - fadeMilliseconds)
        if leadMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(leadMilliseconds))
        }
        guard !Task.isCancelled, fadeMilliseconds > 0 else { return }
        let initialVolume = Float(settings.volume)
        let steps = 20
        for step in 1...steps where !Task.isCancelled {
            session.audioReceiver.volume = initialVolume * Float(steps - step) / Float(steps)
            try? await Task.sleep(
                for: .milliseconds(max(1, fadeMilliseconds / steps)))
        }
    }

    private func metadataLine(for header: SIDHeader) -> String {
        var values = [header.author, header.released].filter { !$0.isEmpty }
        if let nowPlayingDurationMilliseconds {
            let seconds = nowPlayingDurationMilliseconds / 1_000
            values.append(
                (nowPlayingUsesFallbackDuration ? "~" : "")
                    + "\(seconds / 60):" + String(format: "%02d", seconds % 60))
        }
        return values.joined(separator: " · ")
    }
}

/// SwiftUI creates offscreen `List` rows eagerly, so an `onAppear` handler on
/// the final row is not a reliable scrolling signal. Watch the actual wheel
/// event instead and request another item only when the user nudges downward
/// at the bottom of this list.
private struct ScrollEndNudgeDetector: NSViewRepresentable {
    let onNudge: () -> Void

    func makeNSView(context: Context) -> ScrollEndNudgeView {
        let view = ScrollEndNudgeView()
        view.onNudge = onNudge
        return view
    }

    func updateNSView(_ view: ScrollEndNudgeView, context: Context) {
        view.onNudge = onNudge
    }
}

private final class ScrollEndNudgeView: NSView {
    var onNudge: (() -> Void)?
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            self?.handleScroll(event)
            return event
        }
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard event.window === window,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let contentView = window?.contentView,
              let hitView = contentView.hitTest(event.locationInWindow),
              let scrollView = hitView.enclosingScrollView,
              (scrollView.verticalScroller?.floatValue ?? 0) >= 0.999
        else { return }
        onNudge?()
    }
}
