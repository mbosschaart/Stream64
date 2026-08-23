import CryptoKit
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The only HVSC network contract used by Stream64.  Tune metadata and SID
/// bytes are read exclusively from the user's local collection.
struct HVSCManifestClient: Sendable {
    static let manifestURL = URL(string: "https://hvsc.de/api/v1/version")!

    struct Manifest: Codable, Equatable, Sendable {
        struct Archive: Codable, Equatable, Sendable {
            let requiredVersion: Int?
            let url: URL
        }

        let version: Int
        let update: Archive
        let complete: Archive
    }

    enum Error: LocalizedError {
        case invalidResponse
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "HVSC's version manifest is invalid."
            case .responseTooLarge: return "HVSC's version manifest is unexpectedly large."
            }
        }
    }

    func fetch() async throws -> Manifest {
        var request = URLRequest(url: Self.manifestURL, timeoutInterval: 30)
        request.setValue("Stream64 local HVSC library", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              response.url?.host == Self.manifestURL.host,
              data.count <= 128 * 1024,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.complete.url.scheme == "https",
              manifest.update.url.scheme == "https" else {
            throw Error.invalidResponse
        }
        guard http.expectedContentLength <= 128 * 1024 else {
            throw Error.responseTooLarge
        }
        return manifest
    }
}

/// A local, full-metadata representation assembled from a SID header and its
/// collection-relative path. This intentionally contains no HVSC web IDs.
struct LocalHVSCTune: Codable, Identifiable, Hashable, Sendable {
    let relativePath: String
    let title: String
    let author: String
    let released: String
    let format: String
    let songs: Int
    let startSong: Int
    let sidRequirements: String
    /// Derived exclusively from PSID/RSID v3/v4 header addresses while
    /// indexing, rather than from a filename or descriptive text convention.
    let sidCount: Int

    var id: String { relativePath }
    var filename: String { (relativePath as NSString).lastPathComponent }
    var searchableText: String {
        [relativePath, filename, title, author, released, format, sidRequirements]
            .joined(separator: " ").folding(options: .diacriticInsensitive, locale: .current)
    }
}

enum HVSCExtractorError: LocalizedError {
    case unavailable
    case invalidArchive
    case untrustedExtractor
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The signed bundled 7z extractor is not included in this build. Select an already extracted HVSC folder instead."
        case .invalidArchive: return "The selected archive is not a .7z file."
        case .untrustedExtractor: return "The bundled 7z extractor did not pass its integrity check."
        case .failed(let reason): return "HVSC extraction failed: \(reason)"
        }
    }
}

/// Extraction is deliberately not delegated to `7z`, `7zz`, Homebrew, or any
/// executable discovered on PATH. A release can opt in by shipping a signed
/// `hvsc-7zz` resource and its SHA-256 in Info.plist.
protocol HVSCArchiveExtracting: Sendable {
    /// Lists archive members before extraction so unsafe paths and link entries
    /// can be rejected before an extractor writes anything.
    func inspect(archive: URL) async throws -> [HVSCArchiveEntry]
    func extract(
        archive: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

struct HVSCArchiveEntry: Equatable, Sendable {
    let path: String
    let isLinkOrSpecial: Bool
}

struct BundledSigned7zExtractor: HVSCArchiveExtracting {
    /// SHA-256 of the official universal 7-Zip 26.02 macOS console binary
    /// vendored in Resources. Keep this in code as well as Info.plist so
    /// SwiftPM development builds receive the same integrity check.
    private static let expectedSHA256 =
        "9c56cf3379a0d8544e9244958b96fdc7c17f9ce70f5a160eb2b41f5f3df96d8c"

    func inspect(archive: URL) async throws -> [HVSCArchiveEntry] {
        guard archive.pathExtension.lowercased() == "7z" else {
            throw HVSCExtractorError.invalidArchive
        }
        let output = try run(arguments: ["l", "-slt", archive.path])
        var entries: [HVSCArchiveEntry] = []
        var path: String?
        var unsafeKind = false
        func appendEntry() {
            guard let path else { return }
            entries.append(.init(path: path, isLinkOrSpecial: unsafeKind))
        }
        for line in output.split(whereSeparator: \.isNewline) {
            if line == "----------" {
                appendEntry()
                path = nil
                unsafeKind = false
            } else if line.hasPrefix("Path = ") {
                appendEntry()
                path = String(line.dropFirst("Path = ".count))
                unsafeKind = false
            } else if line.hasPrefix("Symbolic Link = ")
                        || line.hasPrefix("Hard Link = ")
                        || line.hasPrefix("Reparse Point = ")
                        || line.hasPrefix("Type = Symbolic Link")
                        || (line.hasPrefix("Attributes = ") && line.lowercased().contains("l")) {
                unsafeKind = true
            }
        }
        appendEntry()
        // `7zz l` starts with archive metadata; it is not a member.
        if entries.first?.path == archive.path || entries.first?.path == archive.lastPathComponent {
            entries.removeFirst()
        }
        guard !entries.isEmpty else { throw HVSCExtractorError.failed("archive has no entries") }
        return entries
    }

    func extract(
        archive: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard archive.pathExtension.lowercased() == "7z" else {
            throw HVSCExtractorError.invalidArchive
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try runExtracting(
            arguments: ["x", "-y", "-bsp1", "-o\(destination.path)", archive.path],
            progress: progress)
    }

    private func verifiedExecutable() throws -> URL {
        guard let executable = Bundle.main.url(
            forResource: "hvsc-7zz", withExtension: nil)
            ?? Bundle.module.url(
                forResource: "hvsc-7zz", withExtension: nil) else {
            throw HVSCExtractorError.unavailable
        }
        let expectedHash = (Bundle.main.object(
            forInfoDictionaryKey: "HVSC7zSHA256") as? String)
            ?? Self.expectedSHA256
        let actualHash = SHA256.hash(data: try Data(contentsOf: executable))
            .map { String(format: "%02x", $0) }.joined()
        guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw HVSCExtractorError.untrustedExtractor
        }
        return executable
    }

    private func run(arguments: [String]) throws -> String {
        let executable = try verifiedExecutable()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        // Archive listings can exceed a pipe buffer. Drain concurrently while
        // the child runs, then decode the complete bounded-in-practice listing.
        let lock = NSLock()
        var output = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            output = data
            lock.unlock()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        lock.lock()
        let text = String(data: output, encoding: .utf8) ?? ""
        lock.unlock()
        guard process.terminationStatus == 0 else {
            throw HVSCExtractorError.failed(String(text.prefix(300)))
        }
        return text
    }

    private func runExtracting(
        arguments: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let process = Process()
        process.executableURL = try verifiedExecutable()
        process.arguments = arguments
        // `-bsp1` emits small, parseable percentage updates. Drain its pipe
        // concurrently: waiting on a process with an undrained output pipe
        // deadlocks once the kernel buffer fills on a full HVSC archive.
        let progressPipe = Pipe()
        process.standardOutput = progressPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let reader = progressPipe.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            var pending = ""
            while true {
                let chunk = reader.availableData
                guard !chunk.isEmpty else { break }
                pending += String(decoding: chunk, as: UTF8.self)
                let pieces = pending.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
                pending = pieces.last.map(String.init) ?? ""
                for piece in pieces.dropLast() + (pending.isEmpty ? [] : [Substring(pending)]) {
                    guard let percent = Self.extractionPercent(in: String(piece)) else { continue }
                    progress(Double(percent) / 100)
                }
            }
        }
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            throw HVSCExtractorError.failed(
                "extractor exited \(process.terminationStatus)")
        }
        progress(1)
    }

    private static func extractionPercent(in output: String) -> Int? {
        guard let percentRange = output.range(of: "%") else { return nil }
        let prefix = output[..<percentRange.lowerBound]
        let digits = prefix.reversed().prefix(while: \.isNumber).reversed()
        guard let value = Int(String(digits)), (0...100).contains(value) else { return nil }
        return value
    }
}

enum HVSCInstallError: LocalizedError {
    case unsafeArchiveEntry(String)
    case unsafeExtractedItem(String)
    case invalidLayout
    case duplicatePath(String)
    case destinationInUse(URL)
    case updateUnavailable
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .unsafeArchiveEntry(let path): return "The archive contains an unsafe entry: \(path)"
        case .unsafeExtractedItem(let path): return "The extracted collection contains an unsafe item: \(path)"
        case .invalidLayout: return "The archive is not a complete HVSC corpus (MUSICIANS and SID files are required)."
        case .duplicatePath(let path): return "The archive contains duplicate paths: \(path)"
        case .destinationInUse(let url): return "\(url.lastPathComponent) already exists. Choose another destination or install an update."
        case .updateUnavailable: return "A compatible Stream64-managed HVSC installation is required for an update."
        case .archiveTooLarge: return "The HVSC archive exceeds the 2 GB safety limit."
        }
    }
}

struct HVSCDownloadProgress: Equatable, Sendable {
    let bytesDownloaded: Int64
    let totalBytes: Int64?
    let bytesPerSecond: Double
    let estimatedTimeRemaining: TimeInterval?
}

struct HVSCIndexProgress: Equatable, Sendable {
    let indexedTunes: Int
    let discoveredSIDFiles: Int
}

private final class HVSCDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedURL: URL
    private let destination: URL
    private let maximumSize: Int64
    private let fileManager: FileManager
    private let progressHandler: @Sendable (HVSCDownloadProgress) -> Void
    private var completion: (@Sendable (Result<URL, Error>) -> Void)?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var failure: Error?
    private var startedAt: TimeInterval?
    private var lastPublishedAt: TimeInterval = 0
    private var completed = false

    init(
        expectedURL: URL,
        destination: URL,
        maximumSize: Int64,
        fileManager: FileManager,
        progressHandler: @escaping @Sendable (HVSCDownloadProgress) -> Void,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        self.expectedURL = expectedURL
        self.destination = destination
        self.maximumSize = maximumSize
        self.fileManager = fileManager
        self.progressHandler = progressHandler
        self.completion = completion
    }

    func setCompletion(_ completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()
    }

    func start(with request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.downloadTask(with: request)
        lock.lock()
        self.session = session
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            task.cancel()
        } else {
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        task?.cancel()
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              response.url == expectedURL else {
            fail(HVSCManifestClient.Error.invalidResponse)
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite < 0
                || totalBytesExpectedToWrite <= maximumSize else {
            fail(HVSCInstallError.archiveTooLarge)
            downloadTask.cancel()
            return
        }
        guard totalBytesWritten <= maximumSize else {
            fail(HVSCInstallError.archiveTooLarge)
            downloadTask.cancel()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if startedAt == nil { startedAt = now }
        guard now - lastPublishedAt >= 0.25 else { return }
        lastPublishedAt = now
        let elapsed = max(now - (startedAt ?? now), 0.001)
        let rate = Double(totalBytesWritten) / elapsed
        let total = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
        let eta = total.flatMap { rate > 0 ? Double($0 - totalBytesWritten) / rate : nil }
        progressHandler(.init(
            bytesDownloaded: totalBytesWritten,
            totalBytes: total,
            bytesPerSecond: rate,
            estimatedTimeRemaining: eta))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard failure == nil else { return }
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              response.url == expectedURL else {
            fail(HVSCManifestClient.Error.invalidResponse)
            return
        }
        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
        } catch {
            fail(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let result: Result<URL, Error>
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(error)
        } else if fileManager.fileExists(atPath: destination.path) {
            result = .success(destination)
        } else {
            result = .failure(HVSCManifestClient.Error.invalidResponse)
        }
        finish(result)
        session.invalidateAndCancel()
        lock.lock()
        self.session = nil
        lock.unlock()
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let completion = completion
        lock.unlock()
        completion?(result)
    }
}

@MainActor
final class HVSCLocalLibrary: ObservableObject {
    private struct ManagedInstall: Codable {
        let version: Int
        let installedAt: Date
    }

    /// A durable, collection-relative playlist. Paths deliberately remain in
    /// the list when a corpus is moved or re-indexed so users can see and
    /// repair unavailable entries instead of silently losing their order.
    struct PlaylistEntry: Codable, Identifiable, Equatable, Sendable {
        let relativePath: String
        let addedAt: Date

        var id: String { relativePath }
    }

    enum Status: Equatable {
        case unconfigured
        case indexing
        case ready(Int)
        case failed(String)
    }

    @Published private(set) var rootURL: URL?
    @Published private(set) var tunes: [LocalHVSCTune] = []
    @Published private(set) var status: Status = .unconfigured
    @Published private(set) var manifest: HVSCManifestClient.Manifest?
    @Published private(set) var manifestStatus: String?
    @Published private(set) var installStatus: String?
    @Published private(set) var installProgress: Double?
    @Published private(set) var downloadProgress: HVSCDownloadProgress?
    @Published private(set) var indexProgress: HVSCIndexProgress?
    @Published private(set) var installPhase: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var playlist: [PlaylistEntry] = [] {
        didSet { savePlaylist() }
    }

    private let bookmarkKey = "hvsc.localRootBookmark"
    private let rootPathKey = "hvsc.localRootPath"
    private let extractor: any HVSCArchiveExtracting
    private let fileManager: FileManager
    private let playlistURL: URL

    init(
        extractor: any HVSCArchiveExtracting = BundledSigned7zExtractor(),
        fileManager: FileManager = .default,
        playlistURL: URL? = nil
    ) {
        self.extractor = extractor
        self.fileManager = fileManager
        self.playlistURL = playlistURL ?? Self.defaultPlaylistURL
        loadPlaylist()
        restoreRoot()
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    func chooseRoot(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = .failed("The selected HVSC folder no longer exists.")
            return
        }
        guard fileManager.fileExists(
            atPath: url.appendingPathComponent("MUSICIANS").path),
            fileManager.fileExists(
                atPath: url.appendingPathComponent("DOCUMENTS").path) else {
            status = .failed(
                "Choose the C64Music folder itself. It must contain both "
                    + "MUSICIANS and DOCUMENTS.")
            return
        }
        do {
            _ = try Self.validatedCorpusRoot(in: url)
        } catch {
            status = .failed(
                "The selected C64Music folder is incomplete or unsafe: "
                    + error.localizedDescription)
            return
        }
        rootURL = url
        saveBookmark(for: url)
        rebuildIndex()
    }

    func rebuildIndex() {
        guard let rootURL else { status = .unconfigured; return }
        status = .indexing
        indexProgress = .init(indexedTunes: 0, discoveredSIDFiles: 0)
        Task {
            do {
                let indexed = try await Task.detached(priority: .utility) {
                    let tunes = try Self.index(root: rootURL) { [weak self] progress in
                        Task { @MainActor in self?.indexProgress = progress }
                    }
                    try? Self.persistSearchIndex(tunes)
                    return tunes
                }.value
                guard self.rootURL == rootURL else { return }
                self.tunes = indexed
                self.status = .ready(indexed.count)
                self.indexProgress = nil
            } catch {
                self.status = .failed(error.localizedDescription)
                self.indexProgress = nil
            }
        }
    }

    /// Revalidate the configured folder whenever the HVSC window opens. The
    /// user may have removed or moved the local corpus outside Stream64.
    func refreshAvailability() {
        guard let rootURL else {
            status = .unconfigured
            return
        }
        guard fileManager.fileExists(atPath: rootURL.path),
              fileManager.fileExists(
                atPath: rootURL.appendingPathComponent("MUSICIANS").path),
              fileManager.fileExists(
                atPath: rootURL.appendingPathComponent("DOCUMENTS").path) else {
            clearLocalLibrary(
                "The local HVSC folder was removed or is incomplete. Choose a C64Music folder to continue.")
            return
        }
    }

    private func clearLocalLibrary(_ message: String? = nil) {
        rootURL = nil
        tunes = []
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: rootPathKey)
        Self.removePersistedSearchIndex()
        status = message.map(Status.failed) ?? .unconfigured
    }

    func fetchManifest() async {
        manifestStatus = "Checking HVSC release…"
        do {
            manifest = try await HVSCManifestClient().fetch()
            manifestStatus = "HVSC #\(manifest!.version) is available."
        } catch {
            manifestStatus = error.localizedDescription
        }
    }

    var canInstallUpdate: Bool {
        guard let rootURL,
              let manifest,
              let current = managedInstall(at: rootURL) else { return false }
        return Self.isCompatibleUpdate(
            installedVersion: current.version,
            manifest: manifest)
    }

    /// Installs only the full or incremental archive URL supplied by the
    /// signed-in-session manifest. `destination` is a folder selected by the
    /// user; the activated corpus is always `<destination>/HVSC`.
    func install(from destination: URL, update: Bool) async {
        guard let manifest else {
            installStatus = "Check the HVSC release before installing."
            return
        }
        guard !isInstalling else { return }
        if update && !canInstallUpdate {
            installStatus = HVSCInstallError.updateUnavailable.localizedDescription
            return
        }
        if update, let rootURL,
           rootURL.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL {
            installStatus = "Choose the folder containing the current managed HVSC installation to apply its update."
            return
        }

        isInstalling = true
        installProgress = nil
        downloadProgress = nil
        installPhase = "Preparing"
        defer {
            isInstalling = false
            installProgress = nil
            downloadProgress = nil
            indexProgress = nil
            installPhase = nil
        }
        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
        do {
            let archive = update ? manifest.update : manifest.complete
            let activation = destination.appendingPathComponent(
                "C64Music", isDirectory: true)
            if !update, fileManager.fileExists(atPath: activation.path) {
                throw HVSCInstallError.destinationInUse(activation)
            }
            installPhase = "Downloading"
            installStatus = "Downloading HVSC #\(manifest.version)…"
            let archiveURL = try await download(archive.url)
            defer { try? fileManager.removeItem(at: archiveURL) }
            installPhase = "Inspecting"
            installStatus = "Inspecting HVSC #\(manifest.version)…"
            let entries = try await extractor.inspect(archive: archiveURL)
            try Self.validateArchiveEntries(entries)

            let candidate: URL
            if update, let rootURL {
                candidate = rootURL.deletingLastPathComponent()
            } else {
                candidate = destination
            }
            installPhase = "Extracting"
            installStatus = "Extracting HVSC #\(manifest.version)…"
            installProgress = 0
            try await extractor.extract(archive: archiveURL, to: candidate) { [weak self] fraction in
                Task { @MainActor in self?.installProgress = fraction }
            }
            let corpus = try Self.validatedInstalledCorpus(at: activation)
            let marker = try JSONEncoder().encode(
                ManagedInstall(version: manifest.version, installedAt: Date()))
            try marker.write(
                to: corpus.appendingPathComponent(".stream64-hvsc-install.json"),
                options: .atomic)

            installPhase = "Validating"
            installStatus = "Validating HVSC #\(manifest.version)…"
            indexProgress = .init(indexedTunes: 0, discoveredSIDFiles: 0)
            let indexed = try await Task.detached(priority: .utility) {
                try Self.index(root: corpus) { [weak self] progress in
                    Task { @MainActor in self?.indexProgress = progress }
                }
            }.value
            installPhase = "Activating"
            installStatus = "Activating HVSC #\(manifest.version)…"
            rootURL = activation
            saveBookmark(for: activation)
            tunes = indexed
            status = .ready(indexed.count)
            indexProgress = nil
            try? await Task.detached(priority: .utility) {
                try Self.persistSearchIndex(indexed)
            }.value
            installStatus = "Installed HVSC #\(manifest.version) (\(indexed.count) tunes)."
        } catch is CancellationError {
            installStatus = "HVSC installation cancelled."
            indexProgress = nil
        } catch {
            installStatus = "HVSC installation failed: \(error.localizedDescription)"
            indexProgress = nil
        }
    }

    func cancelInstall() {
        // The view cancels its task. This state update makes cancellation
        // immediate while URLSession cooperatively stops the streamed download.
        installStatus = "Cancelling HVSC installation…"
    }

    func search(
        _ query: String,
        collection: HVSCClient.SearchFilters.Collection = .all
    ) -> [LocalHVSCTune] {
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        return Self.filteredTunes(tunes, terms: terms, collection: collection)
    }

    func folders(at relativePath: String = "") -> [String] {
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        return Set(tunes.compactMap { tune -> String? in
            guard tune.relativePath.hasPrefix(prefix) else { return nil }
            let remainder = tune.relativePath.dropFirst(prefix.count)
            guard let folder = remainder.split(separator: "/").first,
                  remainder.contains("/") else { return nil }
            return String(folder)
        })
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func tunes(directlyIn relativePath: String) -> [LocalHVSCTune] {
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        return tunes.filter { tune in
            guard tune.relativePath.hasPrefix(prefix) else { return false }
            return !tune.relativePath.dropFirst(prefix.count).contains("/")
        }
    }

    func data(for tune: LocalHVSCTune) throws -> Data {
        guard let rootURL else { throw CocoaError(.fileNoSuchFile) }
        let url = rootURL.appendingPathComponent(tune.relativePath)
        let rootPath = rootURL.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        _ = try SIDHeader(data: data)
        return data
    }

    func tune(for entry: PlaylistEntry) -> LocalHVSCTune? {
        tunes.first {
            $0.relativePath.caseInsensitiveCompare(entry.relativePath)
                == .orderedSame
        }
    }

    func addToPlaylist(_ tune: LocalHVSCTune) {
        guard !playlist.contains(where: {
            $0.relativePath.caseInsensitiveCompare(tune.relativePath)
                == .orderedSame
        }) else { return }
        playlist.append(.init(relativePath: tune.relativePath, addedAt: Date()))
    }

    func removeFromPlaylist(_ entry: PlaylistEntry) {
        playlist.removeAll { $0.id == entry.id }
    }

    func movePlaylistEntry(from index: Int, by offset: Int) {
        let destination = index + offset
        guard playlist.indices.contains(index),
              playlist.indices.contains(destination) else { return }
        playlist.swapAt(index, destination)
    }

    func clearPlaylist() {
        playlist.removeAll()
    }

    private func saveBookmark(for url: URL) {
        let normalized = url.standardizedFileURL
        UserDefaults.standard.set(normalized.path, forKey: rootPathKey)
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil,
            relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }
    }

    private static var defaultPlaylistURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
            .appendingPathComponent("Stream64", isDirectory: true)
            .appendingPathComponent("hvsc-local-playlist.json")
    }

    private func loadPlaylist() {
        guard let data = try? Data(contentsOf: playlistURL),
              let restored = try? JSONDecoder().decode(
                [PlaylistEntry].self, from: data)
        else { return }
        playlist = restored
    }

    private func savePlaylist() {
        guard let data = try? JSONEncoder().encode(playlist) else { return }
        try? fileManager.createDirectory(
            at: playlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: playlistURL, options: .atomic)
    }

    private func managedInstall(at root: URL) -> ManagedInstall? {
        let marker = root.appendingPathComponent(".stream64-hvsc-install.json")
        guard let data = try? Data(contentsOf: marker) else { return nil }
        return try? JSONDecoder().decode(ManagedInstall.self, from: data)
    }

    nonisolated static func isCompatibleUpdate(
        installedVersion: Int,
        manifest: HVSCManifestClient.Manifest
    ) -> Bool {
        manifest.update.requiredVersion == installedVersion
    }

    nonisolated static func filteredTunes(
        _ tunes: [LocalHVSCTune],
        terms: [String] = [],
        collection: HVSCClient.SearchFilters.Collection = .all
    ) -> [LocalHVSCTune] {
        tunes.filter { tune in
            let inCollection: Bool
            switch collection {
            case .all: inCollection = true
            case .twoSID: inCollection = tune.sidCount == 2
            case .threeSID: inCollection = tune.sidCount >= 3
            }
            return inCollection
                && terms.allSatisfy(tune.searchableText.localizedCaseInsensitiveContains)
        }
    }

    private func download(_ url: URL) async throws -> URL {
        guard url.scheme == "https" else { throw HVSCManifestClient.Error.invalidResponse }
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("stream64-hvsc-\(UUID().uuidString).7z")
        let limit = Int64(2 * 1024 * 1024 * 1024)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Stream64 local HVSC library", forHTTPHeaderField: "User-Agent")

        let delegate = HVSCDownloadDelegate(
            expectedURL: url,
            destination: temporary,
            maximumSize: limit,
            fileManager: fileManager,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    if let total = progress.totalBytes, total > 0 {
                        self?.installProgress = Double(progress.bytesDownloaded) / Double(total)
                    } else {
                        self?.installProgress = nil
                    }
                }
            },
            completion: { _ in })
        do {
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.setCompletion { result in continuation.resume(with: result) }
                    delegate.start(with: request)
                }
            }, onCancel: {
                delegate.cancel()
            })
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func activate(corpus: URL, at activation: URL, stage: URL) throws {
        let backup = stage.appendingPathComponent("previous", isDirectory: true)
        if fileManager.fileExists(atPath: activation.path) {
            try fileManager.moveItem(at: activation, to: backup)
        }
        do {
            try fileManager.moveItem(at: corpus, to: activation)
            try? fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: backup.path),
               !fileManager.fileExists(atPath: activation.path) {
                try? fileManager.moveItem(at: backup, to: activation)
            }
            throw error
        }
    }

    nonisolated static func validateArchiveEntries(_ entries: [HVSCArchiveEntry]) throws {
        var seen = Set<String>()
        for entry in entries {
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
                  !components.contains(".."), !components.contains("."),
                  !components.contains(where: { $0.isEmpty }) else {
                throw HVSCInstallError.unsafeArchiveEntry(entry.path)
            }
            guard !entry.isLinkOrSpecial else {
                throw HVSCInstallError.unsafeArchiveEntry(entry.path)
            }
            let key = path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else {
                throw HVSCInstallError.duplicatePath(entry.path)
            }
        }
    }

    /// Returns a single complete corpus root and rejects links, aliases,
    /// non-regular files, duplicate case-folded paths, and an empty layout.
    nonisolated static func validatedCorpusRoot(in staging: URL) throws -> URL {
        let children = try FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [])
        let root: URL
        if FileManager.default.fileExists(atPath: staging.appendingPathComponent("MUSICIANS").path) {
            root = staging
        } else if children.count == 1 {
            let child = children[0]
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: child.appendingPathComponent("MUSICIANS").path) else {
                throw HVSCInstallError.invalidLayout
            }
            root = child
        } else {
            throw HVSCInstallError.invalidLayout
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants])
        var paths = Set<String>()
        var sidCount = 0
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: keys)
            let relative = item.path.replacingOccurrences(of: root.path + "/", with: "")
            guard values.isSymbolicLink != true, values.isAliasFile != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw HVSCInstallError.unsafeExtractedItem(relative)
            }
            let key = relative.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard paths.insert(key).inserted else { throw HVSCInstallError.duplicatePath(relative) }
            if values.isRegularFile == true, item.pathExtension.lowercased() == "sid" {
                sidCount += 1
            }
        }
        guard sidCount > 0 else { throw HVSCInstallError.invalidLayout }
        return root
    }

    /// Official HVSC full archives expand to `C64Music/` in the destination
    /// selected by the user. Keep this check intentionally quick so installs
    /// do not spend minutes enumerating a solid archive before extraction.
    nonisolated static func validatedInstalledCorpus(at root: URL) throws -> URL {
        let musicians = root.appendingPathComponent("MUSICIANS", isDirectory: true)
        let documents = root.appendingPathComponent("DOCUMENTS", isDirectory: true)
        let songlengths = documents.appendingPathComponent("Songlengths.md5")
        guard FileManager.default.fileExists(atPath: musicians.path),
              FileManager.default.fileExists(atPath: documents.path),
              FileManager.default.fileExists(atPath: songlengths.path) else {
            throw HVSCInstallError.invalidLayout
        }
        return root
    }

    private func restoreRoot() {
        var isStale = false
        let defaults = UserDefaults.standard
        let bookmarkedURL = defaults.data(forKey: bookmarkKey).flatMap { data in
            try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        }
        let url = bookmarkedURL
            ?? defaults.string(forKey: rootPathKey).map(URL.init(fileURLWithPath:))
        guard let url else { return }
        rootURL = url
        refreshAvailability()
        if rootURL != nil {
            rebuildIndex()
        }
    }

    nonisolated private static func index(
        root: URL,
        progress: @escaping @Sendable (HVSCIndexProgress) -> Void = { _ in }
    ) throws -> [LocalHVSCTune] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var tunes: [LocalHVSCTune] = []
        var discoveredSIDFiles = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "sid" else { continue }
            discoveredSIDFiles += 1
            if discoveredSIDFiles.isMultiple(of: 128) {
                progress(.init(
                    indexedTunes: tunes.count,
                    discoveredSIDFiles: discoveredSIDFiles))
            }
            guard
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let header = try? SIDHeader(data: data) else { continue }
            let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let requirements = [header.primarySIDModel,
                                header.secondSIDAddress.map { _ in "2SID" },
                                header.thirdSIDAddress.map { _ in "3SID" }]
                .compactMap { $0 }.joined(separator: " · ")
            tunes.append(.init(relativePath: path, title: header.title.isEmpty ? url.deletingPathExtension().lastPathComponent : header.title,
                               author: header.author, released: header.released,
                               format: header.format.rawValue, songs: header.numberOfSongs,
                               startSong: header.startSong,
                               sidRequirements: requirements.isEmpty ? "Unspecified" : requirements,
                               sidCount: header.thirdSIDAddress == nil
                                    ? (header.secondSIDAddress == nil ? 1 : 2)
                                    : 3))
        }
        progress(.init(indexedTunes: tunes.count, discoveredSIDFiles: discoveredSIDFiles))
        return tunes.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// A durable SQLite/FTS5 copy accelerates future evolution without making
    /// library availability depend on SQLite. The in-memory index remains the
    /// safe fallback if the OS SQLite build lacks FTS5 or disk writes fail.
    nonisolated private static func persistSearchIndex(_ tunes: [LocalHVSCTune]) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("Stream64", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("hvsc-local.sqlite").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let database else { return }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, """
            PRAGMA journal_mode=WAL;
            DROP TABLE IF EXISTS tunes;
            DROP TABLE IF EXISTS tunes_fts;
            CREATE TABLE tunes (path TEXT PRIMARY KEY, title TEXT, author TEXT, released TEXT,
                                format TEXT, songs INTEGER, start_song INTEGER, requirements TEXT);
            CREATE VIRTUAL TABLE tunes_fts USING fts5(path, title, author, released, tokenize='unicode61');
            CREATE TRIGGER tunes_fts_insert AFTER INSERT ON tunes BEGIN
                INSERT INTO tunes_fts(rowid, path, title, author, released)
                VALUES (new.rowid, new.path, new.title, new.author, new.released);
            END;
            """, nil, nil, nil) == SQLITE_OK else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, """
            INSERT INTO tunes VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        for tune in tunes {
            sqlite3_bind_text(statement, 1, tune.relativePath, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, tune.title, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, tune.author, -1, sqliteTransient)
            sqlite3_bind_text(statement, 4, tune.released, -1, sqliteTransient)
            sqlite3_bind_text(statement, 5, tune.format, -1, sqliteTransient)
            sqlite3_bind_int(statement, 6, Int32(tune.songs))
            sqlite3_bind_int(statement, 7, Int32(tune.startSong))
            sqlite3_bind_text(statement, 8, tune.sidRequirements, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else { return }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    nonisolated private static func removePersistedSearchIndex() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stream64", isDirectory: true)
        let database = support.appendingPathComponent("hvsc-local.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: database.path + suffix))
        }
    }
}
