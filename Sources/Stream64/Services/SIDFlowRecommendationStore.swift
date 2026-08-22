import CryptoKit
import Foundation

/// Stable SIDFlow identity. A SID file can contain several independently
/// selectable tunes, so the subsong is part of the key.
struct SIDFlowTrackKey: Codable, Hashable, Identifiable, Sendable {
    let sidPath: String
    let songIndex: Int

    var id: String { "\(sidPath)#\(songIndex)" }
    var filename: String { (sidPath as NSString).lastPathComponent }
}

struct SIDFlowRecommendation: Identifiable, Hashable, Sendable {
    let key: SIDFlowTrackKey
    let score: Double
    let reason: String

    var id: String { key.id }
}

enum SIDStationFeedback: String, Codable, Sendable {
    case liked
    case disliked
}

struct SIDStationHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    let key: SIDFlowTrackKey
    let startedAt: Date
    var endedAt: Date?
    var listenedMilliseconds: Int
    var completion: Completion

    enum Completion: String, Codable, Sendable {
        case completed, skipped, failed, replaced
    }

    var id: String { "\(key.id)#\(startedAt.timeIntervalSince1970)" }
}

/// The subset of the published sidecar that Stream64 needs. Additional fields
/// are deliberately ignored so a backwards-compatible data release does not
/// require an app update.
struct SIDFlowLiteManifest: Codable, Equatable, Sendable {
    let schemaVersion: String
    let generatedAt: String
    let corpusVersion: String
    let hvscVersion: String?
    let trackCount: Int
    let fileCount: Int
    let vectorDimensions: Int
    let similarityMetric: String
    let vectorWeights: [Double]?
    let bundleBytes: Int
    let fileChecksums: FileChecksums

    struct FileChecksums: Codable, Equatable, Sendable {
        let bundleSHA256: String

        enum CodingKeys: String, CodingKey {
            case bundleSHA256 = "bundle_sha256"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case corpusVersion = "corpus_version"
        case hvscVersion = "hvsc_version"
        case trackCount = "track_count"
        case fileCount = "file_count"
        case vectorDimensions = "vector_dimensions"
        case similarityMetric = "similarity_metric"
        case vectorWeights = "vector_weights"
        case bundleBytes = "bundle_bytes"
        case fileChecksums = "file_checksums"
    }
}

enum SIDFlowLiteError: LocalizedError, Equatable {
    case invalidManifest
    case unsupportedSchema(String)
    case checksumMismatch
    case malformedBundle(String)
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "SIDFlow's recommendation manifest is invalid."
        case .unsupportedSchema(let schema): return "Unsupported SIDFlow data schema: \(schema)."
        case .checksumMismatch: return "SIDFlow recommendation data failed its checksum."
        case .malformedBundle(let reason): return "SIDFlow recommendation data is malformed: \(reason)"
        case .responseTooLarge: return "SIDFlow recommendation data is larger than expected."
        }
    }
}

/// A native reader for the documented sidcorr-lite-1 file. It contains no
/// SIDFlow source or runtime; it reads only the published binary contract.
struct SIDFlowLiteBundle: Sendable {
    private(set) var tracks: [Track]
    private let tracksByKey: [SIDFlowTrackKey: Int]
    private let codebooks: [[Float]]
    private let weights: [Double]

    struct Track: Sendable {
        let key: SIDFlowTrackKey
        let codes: [UInt8]
    }

    init(data: Data, manifest: SIDFlowLiteManifest) throws {
        guard manifest.schemaVersion == "sidcorr-lite-1" else {
            throw SIDFlowLiteError.unsupportedSchema(manifest.schemaVersion)
        }
        var reader = BinaryReader(data)
        guard reader.readASCII(count: 8) == "SIDCORR\u{0}" else {
            throw SIDFlowLiteError.malformedBundle("missing SIDCORR header")
        }
        guard reader.readUInt16() == 1 else {
            throw SIDFlowLiteError.malformedBundle("unsupported binary version")
        }
        let headerBytes = Int(try reader.require(reader.readUInt16(), "missing header length"))
        guard headerBytes == 32, headerBytes <= data.count else {
            throw SIDFlowLiteError.malformedBundle("invalid header length")
        }
        try reader.seek(12)
        let dimensions = Int(try reader.require(reader.readUInt16(), "missing vector dimensions"))
        let fileIDWidth = Int(try reader.require(reader.readUInt8(), "missing file ID width"))
        let songIndexWidth = Int(try reader.require(reader.readUInt8(), "missing song index width"))
        let subspaces = Int(try reader.require(reader.readUInt16(), "missing PQ subspaces"))
        let centroids = Int(try reader.require(reader.readUInt16(), "missing PQ centroids"))
        _ = reader.readUInt16() // cluster count; current public data has one
        _ = reader.readUInt16() // model flags
        let codebookOffset = Int(try reader.require(reader.readUInt32(), "missing codebook offset"))
        let epochOffset = Int(try reader.require(reader.readUInt32(), "missing epoch offset"))
        guard dimensions == manifest.vectorDimensions,
              subspaces == dimensions,
              (fileIDWidth == 2 || fileIDWidth == 3),
              (songIndexWidth == 1 || songIndexWidth == 2) else {
            throw SIDFlowLiteError.malformedBundle("incompatible header fields")
        }

        try reader.seek(codebookOffset)
        guard Int(try reader.require(reader.readUInt16(), "missing codebook dimensions")) == dimensions,
              Int(try reader.require(reader.readUInt16(), "missing codebook centroids")) == centroids else {
            throw SIDFlowLiteError.malformedBundle("codebook metadata does not match header")
        }
        var decodedCodebooks = Array(
            repeating: [Float](repeating: 0, count: centroids),
            count: dimensions)
        for dimension in 0..<dimensions {
            for centroid in 0..<centroids {
                decodedCodebooks[dimension][centroid] = try reader.readFloat32()
            }
        }

        let footer = try LegacyFooter(data: data)
        guard footer.trackCount == manifest.trackCount,
              footer.fileCount == manifest.fileCount else {
            throw SIDFlowLiteError.malformedBundle("manifest count does not match footer")
        }
        try reader.seek(Int(footer.indexOffset))
        let indexedEpochOffset = Int(try reader.require(reader.readUInt64(), "missing index epoch offset"))
        let indexedEpochLength = Int(try reader.require(reader.readUInt64(), "missing index epoch length"))
        let indexedTrackBase = Int(try reader.require(reader.readUInt32(), "missing index track base"))
        let indexedTrackCount = Int(try reader.require(reader.readUInt32(), "missing index track count"))
        let indexedFileCount = Int(try reader.require(reader.readUInt32(), "missing index file count"))
        _ = reader.readUInt32()
        guard indexedEpochOffset == epochOffset, indexedTrackBase == 0,
              indexedTrackCount == manifest.trackCount,
              indexedFileCount == manifest.fileCount,
              indexedEpochLength > 0,
              epochOffset + indexedEpochLength <= Int(footer.indexOffset) else {
            throw SIDFlowLiteError.malformedBundle("invalid index")
        }
        try reader.seek(epochOffset)
        let trackCount = Int(try reader.require(reader.readUInt32(), "missing epoch track count"))
        let fileCount = Int(try reader.require(reader.readUInt32(), "missing epoch file count"))
        let fileDictionaryBytes = Int(try reader.require(reader.readUInt32(), "missing file dictionary size"))
        let trackTableBytes = Int(try reader.require(reader.readUInt32(), "missing track table size"))
        try reader.skip(24) // remaining reserved epoch header fields
        guard trackCount == manifest.trackCount, fileCount == manifest.fileCount else {
            throw SIDFlowLiteError.malformedBundle("epoch counts do not match manifest")
        }
        let dictionaryEnd = reader.offset + fileDictionaryBytes
        guard dictionaryEnd <= data.count else {
            throw SIDFlowLiteError.malformedBundle("invalid file dictionary bounds")
        }
        var files: [String] = []
        while reader.offset < dictionaryEnd {
            let length = Int(try reader.require(reader.readUInt16(), "missing path length"))
            let bytes = try reader.readBytes(length)
            guard let path = String(bytes: bytes, encoding: .utf8) else {
                throw SIDFlowLiteError.malformedBundle("file path is not UTF-8")
            }
            files.append(path)
        }
        guard files.count == fileCount else {
            throw SIDFlowLiteError.malformedBundle("file dictionary count mismatch")
        }
        let trackRowBytes = fileIDWidth + songIndexWidth + 2 + dimensions
        guard trackTableBytes == trackCount * trackRowBytes,
              reader.offset + trackTableBytes <= Int(footer.indexOffset) else {
            throw SIDFlowLiteError.malformedBundle("track table size does not match header")
        }
        var decoded: [Track] = []
        decoded.reserveCapacity(trackCount)
        for _ in 0..<trackCount {
            let fileID = try reader.readWidth(fileIDWidth)
            let songIndex = try reader.readWidth(songIndexWidth)
            try reader.skip(2) // compact ratings are not a recommendation input
            let codes = try reader.readBytes(dimensions)
            guard files.indices.contains(fileID) else {
                throw SIDFlowLiteError.malformedBundle("track references missing file")
            }
            decoded.append(Track(
                key: .init(sidPath: files[fileID], songIndex: songIndex),
                codes: codes))
        }
        guard decoded.count == manifest.trackCount else {
            throw SIDFlowLiteError.malformedBundle("decoded track count mismatch")
        }
        guard Set(decoded.map(\.key)).count == decoded.count else {
            throw SIDFlowLiteError.malformedBundle("duplicate track identity")
        }
        tracks = decoded
        tracksByKey = Dictionary(uniqueKeysWithValues: decoded.enumerated().map { ($0.element.key, $0.offset) })
        codebooks = decodedCodebooks
        weights = manifest.similarityMetric == "weighted-cosine"
            ? (manifest.vectorWeights ?? [])
            : Array(repeating: 1, count: dimensions)
        guard weights.count == dimensions else {
            throw SIDFlowLiteError.malformedBundle("similarity weights do not match vector dimensions")
        }
    }

    func recommendations(
        seededBy seeds: Set<SIDFlowTrackKey>,
        excluding excluded: Set<SIDFlowTrackKey>,
        limit: Int = 20
    ) -> [SIDFlowRecommendation] {
        let seedTracks = seeds.compactMap { tracksByKey[$0].map { tracks[$0] } }
        guard !seedTracks.isEmpty else { return [] }
        return tracks.enumerated()
            .compactMap { index, track -> SIDFlowRecommendation? in
                guard !excluded.contains(track.key), !seeds.contains(track.key) else { return nil }
                let score = seedTracks.map { weightedCosine($0, track) }.reduce(0, +)
                    / Double(seedTracks.count)
                return .init(
                    key: track.key,
                    score: score,
                    reason: "Similar to your liked SID")
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private func weightedCosine(_ left: Track, _ right: Track) -> Double {
        var dot = 0.0
        var leftMagnitude = 0.0
        var rightMagnitude = 0.0
        for index in codebooks.indices {
            let leftValue = Double(codebooks[index][Int(left.codes[index])])
            let rightValue = Double(codebooks[index][Int(right.codes[index])])
            let weight = weights[index]
            dot += weight * leftValue * rightValue
            leftMagnitude += weight * leftValue * leftValue
            rightMagnitude += weight * rightValue * rightValue
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return -1 }
        return dot / (leftMagnitude.squareRoot() * rightMagnitude.squareRoot())
    }
}

@MainActor
final class SIDFlowRecommendationStore: ObservableObject {
    static let releaseBaseURL = URL(string:
        "https://github.com/chrisgleissner/sidflow-data/releases/latest/download/")!
    static let bundleName = "sidcorr-hvsc-full-sidcorr-lite-1.sidcorr"
    static let manifestName = "sidcorr-hvsc-full-sidcorr-lite-1.manifest.json"
    static let checksumsName = "SHA256SUMS"
    static let maximumBundleBytes = 20 * 1024 * 1024

    @Published private(set) var manifest: SIDFlowLiteManifest?
    @Published private(set) var status = "Recommendation data is not installed."
    @Published private(set) var isLoading = false
    @Published private(set) var recommendations: [SIDFlowRecommendation] = []

    private var bundle: SIDFlowLiteBundle?
    private var preferences = Preferences()
    private let cacheDirectory: URL
    private let session: URLSession

    init(cacheDirectory: URL? = nil, session: URLSession = .shared) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory
        self.session = session
        loadPreferences()
        loadCached()
    }

    var isInstalled: Bool { bundle != nil }
    var likedKeys: Set<SIDFlowTrackKey> {
        Set(preferences.liked.map(Self.canonicalKey))
    }
    var history: [SIDStationHistoryEntry] { preferences.history }
    var feedback: [SIDFlowTrackKey: SIDStationFeedback] { preferences.feedback }

    func downloadLatest() async {
        guard !isLoading else { return }
        isLoading = true
        status = "Downloading SIDFlow recommendation data…"
        defer { isLoading = false }
        do {
            let manifestURL = Self.releaseBaseURL.appendingPathComponent(Self.manifestName)
            let bundleURL = Self.releaseBaseURL.appendingPathComponent(Self.bundleName)
            async let manifestData = fetch(manifestURL, maximumBytes: 512 * 1024)
            async let bundleData = fetch(bundleURL, maximumBytes: Self.maximumBundleBytes)
            async let checksumsData = fetch(
                Self.releaseBaseURL.appendingPathComponent(Self.checksumsName),
                maximumBytes: 512 * 1024)
            let manifestPayload = try await manifestData
            let decodedManifest = try JSONDecoder().decode(SIDFlowLiteManifest.self, from: manifestPayload)
            guard decodedManifest.schemaVersion == "sidcorr-lite-1" else {
                throw SIDFlowLiteError.unsupportedSchema(decodedManifest.schemaVersion)
            }
            let downloadedBundle = try await bundleData
            let expectedChecksum = try Self.checksum(
                for: Self.bundleName,
                in: try await checksumsData)
            let actualChecksum = Self.sha256(downloadedBundle)
            guard downloadedBundle.count == decodedManifest.bundleBytes,
                  actualChecksum == decodedManifest.fileChecksums.bundleSHA256.lowercased(),
                  actualChecksum == expectedChecksum else {
                throw SIDFlowLiteError.checksumMismatch
            }
            let decodedBundle = try SIDFlowLiteBundle(data: downloadedBundle, manifest: decodedManifest)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try downloadedBundle.write(to: bundleURLOnDisk, options: .atomic)
            try manifestPayload.write(to: manifestURLOnDisk, options: .atomic)
            manifest = decodedManifest
            bundle = decodedBundle
            rebuildRecommendations()
            status = "SIDFlow data ready: \(decodedManifest.trackCount) subtunes."
        } catch {
            status = "SIDFlow data was not updated: \(error.localizedDescription)"
        }
    }

    func removeDownloadedData() {
        try? FileManager.default.removeItem(at: bundleURLOnDisk)
        try? FileManager.default.removeItem(at: manifestURLOnDisk)
        manifest = nil
        bundle = nil
        recommendations = []
        status = "Recommendation data removed. Listening history was kept."
    }

    func like(_ key: SIDFlowTrackKey) {
        let key = Self.canonicalKey(key)
        preferences.liked.insert(key)
        preferences.skipped.remove(key)
        preferences.feedback[key] = .liked
        savePreferences()
        objectWillChange.send()
    }

    func skip(_ key: SIDFlowTrackKey) {
        let key = Self.canonicalKey(key)
        preferences.skipped.insert(key)
        preferences.liked.remove(key)
        preferences.feedback[key] = .disliked
        savePreferences()
        objectWillChange.send()
    }

    func recordPlayed(_ key: SIDFlowTrackKey) {
        let key = Self.canonicalKey(key)
        preferences.history.removeAll { $0.key == key }
        preferences.history.insert(.init(
            key: key, startedAt: Date(), endedAt: nil,
            listenedMilliseconds: 0, completion: .replaced), at: 0)
        preferences.history = Array(preferences.history.prefix(100))
        savePreferences()
    }

    func finishPlaying(
        _ key: SIDFlowTrackKey,
        listenedMilliseconds: Int,
        completion: SIDStationHistoryEntry.Completion
    ) {
        let key = Self.canonicalKey(key)
        guard let index = preferences.history.firstIndex(where: {
            $0.key == key && $0.endedAt == nil
        }) else { return }
        preferences.history[index].endedAt = Date()
        preferences.history[index].listenedMilliseconds = max(0, listenedMilliseconds)
        preferences.history[index].completion = completion
        savePreferences()
    }

    func clearHistory() {
        preferences.history.removeAll()
        savePreferences()
    }

    func undoFeedback(for key: SIDFlowTrackKey) {
        let key = Self.canonicalKey(key)
        preferences.feedback.removeValue(forKey: key)
        preferences.liked.remove(key)
        preferences.skipped.remove(key)
        savePreferences()
        objectWillChange.send()
    }

    func rebuildRecommendations(limit: Int = 20) {
        guard let bundle else {
            recommendations = []
            return
        }
        let excluded = Set(preferences.skipped.map(Self.canonicalKey))
            .union(preferences.history.map(\.key))
        recommendations = bundle.recommendations(
            seededBy: likedKeys,
            excluding: excluded,
            limit: limit)
    }

    /// Calculates a fresh page away from the main actor. Ranking scans the
    /// whole SIDFlow corpus, so station playback must not make the UI wait
    /// for it at the end of a queue.
    func freshRecommendations(
        excluding additionalExclusions: Set<SIDFlowTrackKey> = [],
        limit: Int = 20,
        diversity: Double = 0,
        pathCooldown: Int = 0
    ) async -> [SIDFlowRecommendation] {
        guard let bundle else { return [] }
        let excluded = Set(preferences.skipped.map(Self.canonicalKey))
            .union(preferences.history.map(\.key))
            .union(additionalExclusions.map(Self.canonicalKey))
        let seeds = likedKeys
        let recentFamilies = Set(preferences.history.prefix(pathCooldown).map {
            Self.pathFamily(for: $0.key)
        })
        return await Task.detached(priority: .utility) {
            let candidates = bundle.recommendations(
                seededBy: seeds, excluding: excluded,
                limit: max(limit, limit * 12))
            guard diversity > 0 else { return Array(candidates.prefix(limit)) }
            var selected: [SIDFlowRecommendation] = []
            var seenFamilies = recentFamilies
            var deferred: [SIDFlowRecommendation] = []
            for candidate in candidates {
                let family = Self.pathFamily(for: candidate.key)
                if seenFamilies.contains(family) {
                    deferred.append(candidate)
                } else {
                    selected.append(candidate)
                    seenFamilies.insert(family)
                    if selected.count == limit { return selected }
                }
            }
            selected.append(contentsOf: deferred.prefix(max(0, limit - selected.count)))
            return selected
        }.value
    }

    private func loadCached() {
        guard let manifestData = try? Data(contentsOf: manifestURLOnDisk),
              let bundleData = try? Data(contentsOf: bundleURLOnDisk),
              let decodedManifest = try? JSONDecoder().decode(SIDFlowLiteManifest.self, from: manifestData),
              decodedManifest.schemaVersion == "sidcorr-lite-1",
              Self.sha256(bundleData) == decodedManifest.fileChecksums.bundleSHA256.lowercased(),
              let decodedBundle = try? SIDFlowLiteBundle(data: bundleData, manifest: decodedManifest)
        else { return }
        manifest = decodedManifest
        bundle = decodedBundle
        status = "Using SIDFlow data from \(decodedManifest.generatedAt)."
        rebuildRecommendations()
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SIDFlowLiteError.invalidManifest
        }
        guard data.count <= maximumBytes else { throw SIDFlowLiteError.responseTooLarge }
        return data
    }

    private static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stream64", isDirectory: true)
            .appendingPathComponent("sidflow-data", isDirectory: true)
    }

    private var bundleURLOnDisk: URL { cacheDirectory.appendingPathComponent(Self.bundleName) }
    private var manifestURLOnDisk: URL { cacheDirectory.appendingPathComponent(Self.manifestName) }
    private var preferencesURL: URL { cacheDirectory.deletingLastPathComponent().appendingPathComponent("sidflow-preferences.json") }

    private struct Preferences: Codable {
        var liked = Set<SIDFlowTrackKey>()
        var skipped = Set<SIDFlowTrackKey>()
        var history = [SIDStationHistoryEntry]()
        var feedback = [SIDFlowTrackKey: SIDStationFeedback]()

        private enum CodingKeys: String, CodingKey {
            case liked, skipped, history, feedback
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            liked = try container.decodeIfPresent(Set<SIDFlowTrackKey>.self, forKey: .liked) ?? []
            skipped = try container.decodeIfPresent(Set<SIDFlowTrackKey>.self, forKey: .skipped) ?? []
            feedback = try container.decodeIfPresent(
                [SIDFlowTrackKey: SIDStationFeedback].self, forKey: .feedback) ?? [:]
            if let entries = try? container.decode(
                [SIDStationHistoryEntry].self, forKey: .history) {
                history = entries
            } else {
                let legacy = try container.decodeIfPresent(
                    [SIDFlowTrackKey].self, forKey: .history) ?? []
                history = legacy.map {
                    .init(key: $0, startedAt: .distantPast, endedAt: nil,
                          listenedMilliseconds: 0, completion: .completed)
                }
            }
        }
    }

    private func loadPreferences() {
        guard let data = try? Data(contentsOf: preferencesURL),
              let saved = try? JSONDecoder().decode(Preferences.self, from: data) else { return }
        preferences = saved
        preferences.liked = Set(preferences.liked.map(Self.canonicalKey))
        preferences.skipped = Set(preferences.skipped.map(Self.canonicalKey))
        preferences.history = preferences.history.map {
            SIDStationHistoryEntry(
                key: Self.canonicalKey($0.key), startedAt: $0.startedAt,
                endedAt: $0.endedAt, listenedMilliseconds: $0.listenedMilliseconds,
                completion: $0.completion)
        }
    }

    private func savePreferences() {
        do {
            let data = try JSONEncoder().encode(preferences)
            try FileManager.default.createDirectory(
                at: preferencesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: preferencesURL, options: .atomic)
        } catch {
            status = "Could not save SID Station preferences: \(error.localizedDescription)"
        }
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func checksum(for filename: String, in data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SIDFlowLiteError.invalidManifest
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let candidate = fields[1].trimmingCharacters(
                in: CharacterSet(charactersIn: " *"))
            guard candidate == filename,
                  fields[0].count == 64,
                  fields[0].allSatisfy({ $0.isHexDigit }) else {
                continue
            }
            return fields[0].lowercased()
        }
        throw SIDFlowLiteError.checksumMismatch
    }

    private static func canonicalKey(_ key: SIDFlowTrackKey) -> SIDFlowTrackKey {
        SIDFlowTrackKey(
            sidPath: key.sidPath.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")),
            // SIDFlow's published `song_index` follows the PSID convention:
            // first subtune is 1. Early Stream64 builds wrote 0 here, so
            // normalise persisted likes/skips/history on read as well.
            songIndex: max(1, key.songIndex))
    }

    nonisolated private static func pathFamily(for key: SIDFlowTrackKey) -> String {
        let components = key.sidPath.split(separator: "/")
        return components.dropLast().prefix(3).joined(separator: "/").lowercased()
    }
}

private struct BinaryReader {
    private let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func seek(_ offset: Int) throws {
        guard (0...data.count).contains(offset) else {
            throw SIDFlowLiteError.malformedBundle("unexpected end of file")
        }
        self.offset = offset
    }

    mutating func skip(_ count: Int) throws { try seek(offset + count) }
    mutating func readUInt8() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func readUInt16() -> UInt16? {
        guard let a = readUInt8(), let b = readUInt8() else { return nil }
        return UInt16(a) | UInt16(b) << 8
    }
    mutating func readUInt32() -> UInt32? {
        guard let a = readUInt16(), let b = readUInt16() else { return nil }
        return UInt32(a) | UInt32(b) << 16
    }
    mutating func readUInt64() -> UInt64? {
        guard let a = readUInt32(), let b = readUInt32() else { return nil }
        return UInt64(a) | UInt64(b) << 32
    }
    mutating func readFloat32() throws -> Float {
        Float(bitPattern: try require(readUInt32(), "missing float"))
    }
    mutating func readASCII(count: Int) -> String? {
        guard let bytes = try? readBytes(count) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else {
            throw SIDFlowLiteError.malformedBundle("unexpected end of file")
        }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }
    mutating func readWidth(_ width: Int) throws -> Int {
        switch width {
        case 1: return Int(try require(readUInt8(), "missing integer"))
        case 2: return Int(try require(readUInt16(), "missing integer"))
        case 3:
            let a = Int(try require(readUInt8(), "missing integer"))
            let b = Int(try require(readUInt8(), "missing integer"))
            let c = Int(try require(readUInt8(), "missing integer"))
            return a | b << 8 | c << 16
        default: throw SIDFlowLiteError.malformedBundle("unsupported integer width")
        }
    }
    func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SIDFlowLiteError.malformedBundle(message) }
        return value
    }
}

private struct LegacyFooter {
    let indexOffset: UInt64
    let fileCount: UInt32
    let trackCount: UInt32

    init(data: Data) throws {
        guard data.count >= 72 else {
            throw SIDFlowLiteError.malformedBundle("missing footer")
        }
        var reader = BinaryReader(data)
        try reader.seek(data.count - 40)
        guard let indexOffset = reader.readUInt64(),
              let indexLength = reader.readUInt64(),
              let epochCount = reader.readUInt32(),
              let fileCount = reader.readUInt32(),
              let trackCount = reader.readUInt32(),
              indexOffset + indexLength <= UInt64(data.count - 40),
              epochCount == 1 else {
            throw SIDFlowLiteError.malformedBundle("invalid footer")
        }
        self.indexOffset = indexOffset
        self.fileCount = fileCount
        self.trackCount = trackCount
    }
}
