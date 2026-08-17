import CryptoKit
import Foundation

/// Interactive client for the endpoints used by HVSC's own web application.
///
/// This deliberately has no paging/crawl API: callers submit one user-entered
/// search, inspect one result, and explicitly download one SID to play.
struct HVSCClient: Sendable {
    static let baseURL = URL(string: "https://www.hvsc.c64.org")!
    static let maximumSearchBytes: Int64 = 2 * 1024 * 1024
    static let maximumSIDBytes: Int64 = 2 * 1024 * 1024
    static let maximumSonglengthBytes: Int64 = 5 * 1024 * 1024

    struct SearchFilters: Equatable, Sendable {
        enum Collection: String, CaseIterable, Identifiable, Sendable {
            case all
            case twoSID
            case threeSID

            var id: String { rawValue }

            var label: String {
                switch self {
                case .all: return "All SIDs"
                case .twoSID: return "2-SID Collection"
                case .threeSID: return "3-SID Collection"
                }
            }

            var searchToken: String? {
                switch self {
                case .all: return nil
                case .twoSID: return "2SID"
                case .threeSID: return "3SID"
                }
            }
        }

        enum Field: String, CaseIterable, Identifiable, Sendable {
            case any = ""
            case title
            case author
            case released
            case filename

            var id: String { rawValue }
            var label: String {
                switch self {
                case .any: return "Any Field"
                case .title: return "Title"
                case .author: return "Author"
                case .released: return "Release"
                case .filename: return "Filename"
                }
            }
        }

        enum SIDModel: String, CaseIterable, Identifiable, Sendable {
            case any = ""
            case mos6581 = "6581"
            case mos8580 = "8580"
            case both

            var id: String { rawValue }
            var label: String {
                switch self {
                case .any: return "Any SID"
                case .mos6581: return "6581"
                case .mos8580: return "8580"
                case .both: return "6581 + 8580"
                }
            }
        }

        enum Clock: String, CaseIterable, Identifiable, Sendable {
            case any = ""
            case pal
            case ntsc
            case both

            var id: String { rawValue }
            var label: String {
                switch self {
                case .any: return "Any Clock"
                case .pal: return "PAL"
                case .ntsc: return "NTSC"
                case .both: return "PAL + NTSC"
                }
            }
        }

        var field: Field = .any
        var model: SIDModel = .any
        var clock: Clock = .any
        var year: Int?
        var collection: Collection = .all
    }

    struct SearchResult: Codable, Identifiable, Hashable, Sendable {
        let id: Int
        let title: String
        let author: String
        let released: String

        func matches(_ query: String) -> Bool {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            return [title, author, released].contains {
                $0.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    struct TuneDetail: Codable, Identifiable, Hashable, Sendable {
        let id: Int
        let filename: String
        let fileFormat: String
        let fileFormatVersion: Int
        let title: String
        let author: String
        let released: String
        let systemPal: Bool
        let systemNtsc: Bool
        let model6581: Bool
        let model8580: Bool
        let playsidSpecific: Bool
        let loadAddress: String
        let initAddress: String
        let playAddress: String
        let startSong: Int
        let numberOfSongs: Int
        let md5: String
        let model6581Sid2: Bool?
        let model8580Sid2: Bool?
        let sid2BaseAddress: String?
        let model6581Sid3: Bool?
        let model8580Sid3: Bool?
        let sid3BaseAddress: String?
        let filePath: String

        var relativePath: String { filePath + filename }

        var videoStandard: String {
            switch (systemPal, systemNtsc) {
            case (true, true): return "PAL + NTSC"
            case (true, false): return "PAL"
            case (false, true): return "NTSC"
            case (false, false): return "Unknown"
            }
        }

        var sidRequirements: String {
            var requirements: [String] = []
            if model6581 { requirements.append("6581") }
            if model8580 { requirements.append("8580") }
            if sid2BaseAddress != nil { requirements.append("2SID") }
            if sid3BaseAddress != nil { requirements.append("3SID") }
            return requirements.isEmpty ? "Unspecified" : requirements.joined(separator: " · ")
        }
    }

    struct CollectionVersion: Codable, Hashable, Sendable {
        struct Download: Codable, Hashable, Sendable {
            let url: URL
        }

        let version: Int
        let update: Download
        let complete: Download
    }

    enum ClientError: LocalizedError {
        case emptyQuery
        case httpError(Int)
        case responseTooLarge(Int64)
        case unexpectedRedirect(URL)
        case invalidContentType(String?)
        case invalidSID(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .emptyQuery:
                return "Enter at least three characters to search HVSC."
            case .httpError(let code):
                return "HVSC returned HTTP \(code)."
            case .responseTooLarge(let bytes):
                return "The HVSC response is too large (\(bytes) bytes)."
            case .unexpectedRedirect(let url):
                return "HVSC redirected the request to an unexpected host (\(url.host ?? url.absoluteString))."
            case .invalidContentType(let type):
                return "HVSC returned an unexpected content type (\(type ?? "unknown"))."
            case .invalidSID(let reason):
                return "The downloaded file is not a supported SID: \(reason)"
            case .malformedResponse:
                return "HVSC returned an invalid response."
            }
        }
    }

    func search(
        query: String,
        filters: SearchFilters = .init()
    ) async throws -> [SearchResult] {
        let url = try Self.searchURL(query: query, filters: filters)
        return try await get(url, maximumBytes: Self.maximumSearchBytes)
    }

    /// Retrieves HVSC's conventionally named multi-SID sets through one
    /// user-initiated search request. HVSC has no separate collection endpoint.
    func searchCollection(
        _ collection: SearchFilters.Collection,
        filters: SearchFilters = .init()
    ) async throws -> [SearchResult] {
        guard let token = collection.searchToken else {
            throw ClientError.emptyQuery
        }
        return try await search(query: token, filters: filters)
    }

    static func searchURL(
        query: String,
        filters: SearchFilters = .init()
    ) throws -> URL {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { throw ClientError.emptyQuery }

        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("/api/v1/sids"),
            resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "q", value: trimmed)]
        if !filters.field.rawValue.isEmpty {
            items.append(URLQueryItem(name: "type", value: filters.field.rawValue))
        }
        if !filters.model.rawValue.isEmpty {
            items.append(URLQueryItem(name: "model", value: filters.model.rawValue))
        }
        if !filters.clock.rawValue.isEmpty {
            items.append(URLQueryItem(name: "clock", value: filters.clock.rawValue))
        }
        if let year = filters.year {
            items.append(URLQueryItem(name: "year", value: String(year)))
        }
        components.queryItems = items
        return components.url!
    }

    func details(id: Int) async throws -> TuneDetail {
        try await get(
            Self.baseURL.appendingPathComponent("/api/v1/sids/\(id)"),
            maximumBytes: Self.maximumSearchBytes)
    }

    func collectionVersion() async throws -> CollectionVersion {
        try await get(
            Self.baseURL.appendingPathComponent("/api/v1/version/7z"),
            maximumBytes: Self.maximumSearchBytes)
    }

    /// Downloads one SID after an explicit user Play action.
    func downloadSID(id: Int) async throws -> Data {
        let data = try await download(
            Self.baseURL.appendingPathComponent("/download/sids/\(id)"),
            maximumBytes: Self.maximumSIDBytes)
        _ = try SIDHeader(data: data)
        return data
    }

    /// Resolves a SIDFlow `(sid_path, song_index)` key only when the user
    /// presses Play. SIDFlow provides stable HVSC paths, whereas HVSC's public
    /// browser API downloads by numeric ID. We therefore perform a narrowly
    /// scoped filename search, inspect a bounded number of returned details,
    /// and keep only the selected SID bytes in memory.
    ///
    /// This intentionally does not cache or prefetch SID files.
    func downloadSID(for key: SIDFlowTrackKey) async throws -> Data {
        var filters = SearchFilters()
        filters.field = .filename
        let filename = (key.sidPath as NSString).lastPathComponent
        let matches = try await search(query: filename, filters: filters)
        let expectedPath = Self.normalizedHVSCPath(key.sidPath)
        for result in matches.prefix(24) {
            let detail = try await details(id: result.id)
            guard Self.normalizedHVSCPath(detail.relativePath) == expectedPath else {
                continue
            }
            return try await downloadSID(id: detail.id)
        }
        throw ClientError.invalidSID("HVSC could not resolve \(key.sidPath)")
    }

    /// The current HVSC distribution exposes this document alongside STIL.
    /// It may be temporarily unavailable; callers retain the previous cache.
    func downloadSonglengths() async throws -> Data {
        try await download(
            Self.baseURL.appendingPathComponent(
                "/download/C64Music/DOCUMENTS/Songlengths.md5"),
            maximumBytes: Self.maximumSonglengthBytes,
            requiresTextContent: true)
    }

    private func get<T: Decodable>(
        _ url: URL,
        maximumBytes: Int64
    ) async throws -> T {
        let data = try await requestData(
            URLRequest(url: url, timeoutInterval: 30),
            maximumBytes: maximumBytes,
            requiresTextContent: true)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.malformedResponse
        }
    }

    private func download(
        _ url: URL,
        maximumBytes: Int64,
        requiresTextContent: Bool = false
    ) async throws -> Data {
        try await requestData(
            URLRequest(url: url, timeoutInterval: 60),
            maximumBytes: maximumBytes,
            requiresTextContent: requiresTextContent)
    }

    private func requestData(
        _ request: URLRequest,
        maximumBytes: Int64,
        requiresTextContent: Bool
    ) async throws -> Data {
        var request = request
        request.setValue(
            "Stream64/1.0 interactive HVSC browser",
            forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.httpError(http.statusCode)
        }
        guard let finalURL = response.url,
              finalURL.scheme == "https",
              finalURL.host == Self.baseURL.host
                || finalURL.host?.hasSuffix(".home.xs4all.nl") == true
        else {
            throw ClientError.unexpectedRedirect(response.url ?? request.url!)
        }
        let contentLength = response.expectedContentLength
        guard contentLength <= maximumBytes, Int64(data.count) <= maximumBytes else {
            throw ClientError.responseTooLarge(max(contentLength, Int64(data.count)))
        }
        if requiresTextContent,
           let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !contentType.contains("json"),
           !contentType.contains("text"),
           !contentType.contains("octet-stream") {
            throw ClientError.invalidContentType(contentType)
        }
        return data
    }

    private static func normalizedHVSCPath(_ path: String) -> String {
        "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Parsed PSID/RSID header used to validate a downloaded SID before it is
/// uploaded to an Ultimate. Header offsets are defined by HVSC's SID format.
struct SIDHeader: Equatable, Sendable {
    enum Format: String, Sendable {
        case psid = "PSID"
        case rsid = "RSID"
    }

    let format: Format
    let version: Int
    let dataOffset: Int
    let title: String
    let author: String
    let released: String
    let numberOfSongs: Int
    let startSong: Int
    let flags: UInt16
    let secondSIDAddress: UInt16?
    let thirdSIDAddress: UInt16?
    let primarySIDModel: String?
    let secondSIDModel: String?
    let thirdSIDModel: String?
    /// PSID files with this flag rely on PlaySID-only behavior and are not
    /// safe to execute on an unmodified C64 SID-player path.
    let isPlaySIDSpecific: Bool

    var requiredSIDAddresses: [UInt16] {
        [0xD400, secondSIDAddress, thirdSIDAddress].compactMap { $0 }
    }

    init(data: Data) throws {
        guard data.count >= 0x76 else {
            throw HVSCClient.ClientError.invalidSID("header is too short")
        }
        let magic = String(decoding: data.prefix(4), as: UTF8.self)
        guard let format = Format(rawValue: magic) else {
            throw HVSCClient.ClientError.invalidSID("missing PSID/RSID signature")
        }
        let version = Self.word(data, at: 0x04)
        guard (1...4).contains(version) else {
            throw HVSCClient.ClientError.invalidSID("unsupported format version \(version)")
        }
        let dataOffset = Self.word(data, at: 0x06)
        guard dataOffset >= (version == 1 ? 0x76 : 0x7C),
              dataOffset < data.count else {
            throw HVSCClient.ClientError.invalidSID("invalid data offset")
        }
        let songCount = Self.word(data, at: 0x0E)
        let startSong = Self.word(data, at: 0x10)
        guard (1...256).contains(songCount),
              (1...songCount).contains(startSong) else {
            throw HVSCClient.ClientError.invalidSID("invalid song count")
        }
        let flags = version >= 2 ? UInt16(Self.word(data, at: 0x76)) : 0
        self.format = format
        self.version = version
        self.dataOffset = dataOffset
        title = Self.text(data, at: 0x16)
        author = Self.text(data, at: 0x36)
        released = Self.text(data, at: 0x56)
        numberOfSongs = songCount
        self.startSong = startSong
        self.flags = flags
        primarySIDModel = Self.sidModel(flags, shift: 4)
        secondSIDModel = Self.sidModel(flags, shift: 6)
        thirdSIDModel = Self.sidModel(flags, shift: 8)
        isPlaySIDSpecific = format == .psid && (flags & 0x0002) != 0
        secondSIDAddress = try Self.additionalSIDAddress(
            data,
            offset: 0x7A,
            requiredByVersion: 3,
            version: version,
            label: "second")
        thirdSIDAddress = try Self.additionalSIDAddress(
            data,
            offset: 0x7B,
            requiredByVersion: 4,
            version: version,
            label: "third")
    }

    private static func word(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) << 8 | Int(data[offset + 1])
    }

    private static func text(_ data: Data, at offset: Int) -> String {
        let bytes = data[offset..<(offset + 32)]
            .prefix { $0 != 0 }
        let text = String(
            data: Data(bytes),
            encoding: .windowsCP1252)
            ?? String(decoding: bytes, as: UTF8.self)
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func additionalSIDAddress(
        _ data: Data,
        offset: Int,
        requiredByVersion: Int,
        version: Int,
        label: String
    ) throws -> UInt16? {
        guard version >= requiredByVersion else { return nil }
        let value = data[offset]
        guard value != 0 else { return nil }
        guard let address = sidAddress(value) else {
            throw HVSCClient.ClientError.invalidSID(
                "invalid \(label) SID address")
        }
        return address
    }

    private static func sidModel(_ flags: UInt16, shift: UInt16) -> String? {
        switch (flags >> shift) & 0x0003 {
        case 1: return "6581"
        case 2: return "8580"
        default: return nil
        }
    }

    private static func sidAddress(_ value: UInt8) -> UInt16? {
        guard value.isMultiple(of: 2),
              value >= 0x42,
              !(0x80...0xDF).contains(value) else {
            return nil
        }
        return UInt16(value) << 4 | 0xD000
    }
}

/// A current-format HVSC Songlengths.md5 snapshot. Durations are milliseconds
/// and are keyed by lowercase full-file SID MD5.
struct HVSCSonglengthDatabase: Codable, Sendable {
    let durationsByMD5: [String: [Int]]

    static func parse(_ data: Data) throws -> HVSCSonglengthDatabase {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
        else {
            throw ParseError.invalidEncoding
        }
        var values: [String: [Int]] = [:]
        var sawHeader = false
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "[Database]" {
                sawHeader = true
                continue
            }
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].count == 32,
                  pair[0].allSatisfy({ $0.isHexDigit })
            else {
                throw ParseError.invalidEntry(line)
            }
            let durations = try pair[1]
                .split(whereSeparator: \.isWhitespace)
                .map { try parseDuration(String($0)) }
            guard !durations.isEmpty else {
                throw ParseError.invalidEntry(line)
            }
            values[String(pair[0]).lowercased()] = durations
        }
        guard sawHeader, !values.isEmpty else {
            throw ParseError.invalidHeader
        }
        return HVSCSonglengthDatabase(durationsByMD5: values)
    }

    func durations(for sidData: Data) -> [Int]? {
        let digest = Insecure.MD5.hash(data: sidData)
            .map { String(format: "%02x", $0) }
            .joined()
        return durationsByMD5[digest]
    }

    enum ParseError: LocalizedError {
        case invalidEncoding
        case invalidHeader
        case invalidEntry(String)
        case invalidDuration(String)

        var errorDescription: String? {
            switch self {
            case .invalidEncoding:
                return "Songlengths database has an unsupported text encoding."
            case .invalidHeader:
                return "Songlengths database is missing its [Database] header."
            case .invalidEntry(let line):
                return "Songlengths database has an invalid entry: \(line.prefix(80))"
            case .invalidDuration(let value):
                return "Songlengths database has an invalid duration: \(value)"
            }
        }
    }

    private static func parseDuration(_ value: String) throws -> Int {
        let pieces = value.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2,
              let minutes = Int(pieces[0]),
              minutes >= 0
        else {
            throw ParseError.invalidDuration(value)
        }
        let secondsAndFraction = pieces[1].split(separator: ".", maxSplits: 1)
        guard let seconds = Int(secondsAndFraction[0]),
              (0...59).contains(seconds) else {
            throw ParseError.invalidDuration(value)
        }
        let milliseconds: Int
        if secondsAndFraction.count == 2 {
            let fraction = secondsAndFraction[1]
            guard (1...3).contains(fraction.count),
                  fraction.allSatisfy(\.isNumber),
                  let raw = Int(fraction) else {
                throw ParseError.invalidDuration(value)
            }
            milliseconds = raw * [100, 10, 1][fraction.count - 1]
        } else {
            milliseconds = 0
        }
        return (minutes * 60 + seconds) * 1_000 + milliseconds
    }
}

/// Persists the optional Songlengths.md5 cache. A failed update never replaces
/// a valid existing database.
@MainActor
final class HVSCLibraryStore: ObservableObject {
    struct SonglengthInfo: Codable, Equatable {
        let hvscVersion: Int?
        let updatedAt: Date
        let entryCount: Int
    }

    struct PlaylistEntry: Codable, Identifiable, Equatable {
        let tune: HVSCClient.TuneDetail
        let addedAt: Date

        var id: Int { tune.id }
    }

    private struct Snapshot: Codable {
        let info: SonglengthInfo
        let database: HVSCSonglengthDatabase
    }

    @Published private(set) var songlengthInfo: SonglengthInfo?
    @Published private(set) var updateStatus: String?
    @Published private(set) var playlist: [PlaylistEntry] = [] {
        didSet { savePlaylist() }
    }
    private var database: HVSCSonglengthDatabase?
    private let storeURL: URL
    private let playlistURL: URL

    init(storeURL: URL? = nil, playlistURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL
        self.playlistURL = playlistURL ?? Self.defaultPlaylistURL
        load()
        loadPlaylist()
    }

    func durations(for sidData: Data) -> [Int]? {
        database?.durations(for: sidData)
    }

    func addToPlaylist(_ tune: HVSCClient.TuneDetail) {
        guard !playlist.contains(where: { $0.tune.id == tune.id }) else {
            updateStatus = "\(tune.title) is already in the playlist."
            return
        }
        playlist.append(PlaylistEntry(tune: tune, addedAt: Date()))
        updateStatus = "Added \(tune.title) to the playlist."
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

    func updateSonglengths(using client: HVSCClient = HVSCClient()) async {
        updateStatus = "Checking HVSC song lengths…"
        do {
            let version = try await client.collectionVersion()
            updateStatus = "Downloading Songlengths.md5…"
            let data = try await client.downloadSonglengths()
            updateStatus = "Validating Songlengths.md5…"
            let parsed = try await Task.detached(priority: .utility) {
                try HVSCSonglengthDatabase.parse(data)
            }.value
            try installSonglengths(
                parsed,
                hvscVersion: version.version,
                updatedAt: Date())
            updateStatus = "Song lengths updated for HVSC #\(version.version)."
        } catch {
            updateStatus = "Song lengths were not updated: \(error.localizedDescription)"
        }
    }

    func importSonglengths(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            Task {
                await importSonglengths(data)
            }
        } catch {
            updateStatus = "Could not import song lengths: \(error.localizedDescription)"
        }
    }

    func importSonglengths(_ data: Data) async {
        updateStatus = "Importing Songlengths.md5…"
        do {
            let parsed = try await Task.detached(priority: .utility) {
                try HVSCSonglengthDatabase.parse(data)
            }.value
            try installSonglengths(
                parsed,
                hvscVersion: nil,
                updatedAt: Date())
            updateStatus = "Imported Songlengths.md5."
        } catch {
            updateStatus = "Could not import song lengths: \(error.localizedDescription)"
        }
    }

    private static var defaultStoreURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Stream64", isDirectory: true)
            .appendingPathComponent("hvsc-songlengths.json")
    }

    private static var defaultPlaylistURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Stream64", isDirectory: true)
            .appendingPathComponent("hvsc-playlist.json")
    }

    private func installSonglengths(
        _ parsed: HVSCSonglengthDatabase,
        hvscVersion: Int?,
        updatedAt: Date
    ) throws {
        let info = SonglengthInfo(
            hvscVersion: hvscVersion,
            updatedAt: updatedAt,
            entryCount: parsed.durationsByMD5.count)
        let snapshot = Snapshot(info: info, database: parsed)
        let encoded = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try encoded.write(to: storeURL, options: .atomic)
        database = parsed
        songlengthInfo = info
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        database = snapshot.database
        songlengthInfo = snapshot.info
    }

    private func loadPlaylist() {
        guard let data = try? Data(contentsOf: playlistURL),
              let restored = try? JSONDecoder().decode(
                [PlaylistEntry].self, from: data) else {
            return
        }
        playlist = restored
    }

    private func savePlaylist() {
        guard let data = try? JSONEncoder().encode(playlist) else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: playlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: playlistURL, options: .atomic)
        } catch {
            updateStatus = "Playlist could not be saved: \(error.localizedDescription)"
        }
    }
}
