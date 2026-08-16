import Foundation

/// Client for the Assembly64 online library (hackerswithstyle.se/leet) —
/// AQL search, item file listings, and binary downloads.
///
/// The API requires a registered `client-id` header on every request;
/// unknown IDs are rejected with errorCode 464.
struct Assembly64Client {
    static let baseURL = URL(string: "https://hackerswithstyle.se/leet")!
    static let clientID = "assembly64"
    static let maximumArchiveBytes: Int64 = 100 * 1024 * 1024
    static let maximumIndividualDownloadBytes: Int64 = 100 * 1024 * 1024

    struct SearchResult: Codable, Identifiable, Hashable {
        let itemID: String
        let name: String
        let category: Int
        let group: String?
        let handle: String?
        let year: Int?
        let rating: Int?
        let siteRating: Double?
        let country: String?
        let event: String?
        let updated: String?
        let released: String?

        var id: String { libraryKey }
        var libraryKey: String { "\(category):\(itemID)" }

        private enum CodingKeys: String, CodingKey {
            case itemID = "id"
            case name, category, group, handle, year, rating, siteRating
            case country, event, updated, released
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)

            if let stringID = try? values.decode(String.self, forKey: .itemID) {
                itemID = stringID
            } else if let numericID = try? values.decode(Int.self, forKey: .itemID) {
                itemID = String(numericID)
            } else {
                throw DecodingError.keyNotFound(
                    CodingKeys.itemID,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Assembly64 result has no item id"))
            }

            if let integerCategory = try? values.decode(
                Int.self, forKey: .category) {
                category = integerCategory
            } else if let stringCategory = try? values.decode(
                String.self, forKey: .category),
                      let integerCategory = Int(stringCategory) {
                category = integerCategory
            } else {
                throw DecodingError.keyNotFound(
                    CodingKeys.category,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Assembly64 result has no category"))
            }

            group = try values.decodeIfPresent(String.self, forKey: .group)
            handle = try values.decodeIfPresent(String.self, forKey: .handle)
            let explicitName = try values.decodeIfPresent(
                String.self, forKey: .name)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            name = explicitName?.isEmpty == false
                ? explicitName!
                : [group, handle]
                    .compactMap { $0 }
                    .first { !$0.isEmpty } ?? "Untitled #\(itemID)"

            year = try values.decodeIfPresent(Int.self, forKey: .year)
            rating = try values.decodeIfPresent(Int.self, forKey: .rating)
            siteRating = try values.decodeIfPresent(
                Double.self, forKey: .siteRating)
            country = try values.decodeIfPresent(String.self, forKey: .country)
            event = try values.decodeIfPresent(String.self, forKey: .event)
            updated = try values.decodeIfPresent(String.self, forKey: .updated)
            released = try values.decodeIfPresent(String.self, forKey: .released)
        }

        var displayGroup: String {
            let g = (group ?? "").replacingOccurrences(of: "_", with: " ")
            return g.isEmpty ? (handle ?? "") : g
        }

        var displayRating: String {
            if let siteRating, siteRating > 0 {
                return String(format: "%.1f", siteRating)
            }
            if let rating, rating > 0 {
                return String(rating)
            }
            return ""
        }
    }

    struct FileEntry: Decodable, Identifiable, Hashable {
        let id: Int
        let path: String
        let size: Int

        var filename: String { (path as NSString).lastPathComponent }
        var fileExtension: String { (filename as NSString).pathExtension.lowercased() }

        var kind: FileKind {
            switch fileExtension {
            case "prg": return .prg
            case "d64", "g64", "d71", "g71", "d81": return .disk
            case "sid": return .sid
            case "crt": return .cartridge
            default: return .other
            }
        }
    }

    enum FileKind {
        case prg, disk, sid, cartridge, other
    }

    struct Category: Codable, Identifiable, Hashable {
        let id: Int
        let name: String
        let description: String?
        let groupingName: String?
        let type: String?
    }

    struct AQLPreset: Codable, Hashable {
        let type: String
        let description: String
        let values: [AQLPresetValue]
    }

    struct AQLPresetValue: Codable, Hashable {
        let id: Int?
        let aqlKey: String
        let name: String?

        var displayName: String { name ?? aqlKey.uppercased() }
    }

    struct Metadata: Codable, Hashable {
        let name: String?
        let group: String?
        let handle: String?
        let releaseDate: String?
        let event: String?
        let eventType: String?
        let rating: String?
        let place: String?
        let url: String?
        let images: [TargetAndPath]?
        let siteImage: String?

        var sourceURL: URL? {
            guard let url else { return nil }
            return Assembly64Client.validWebURL(url)
        }

        var imageURLs: [URL] {
            var values: [URL] = []

            if let siteImage, let url = Self.resolve(siteImage, relativeTo: nil) {
                values.append(url)
            }
            for image in images ?? [] {
                if let url = Self.resolve(image.path, relativeTo: image.target) {
                    values.append(url)
                }
            }
            return Array(Set(values))
        }

        private static func resolve(_ path: String?, relativeTo target: String?) -> URL? {
            guard let path, !path.isEmpty else { return nil }
            if let direct = Assembly64Client.validWebURL(path) {
                return direct
            }
            if let target, let base = Assembly64Client.validWebURL(target) {
                return base.appendingPathComponent(path)
            }
            if path.hasPrefix("/") {
                return URL(string: "https://hackerswithstyle.se\(path)")
            }
            return Assembly64Client.baseURL.appendingPathComponent(path)
        }
    }

    static func validWebURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    struct TargetAndPath: Codable, Hashable {
        let path: String?
        let target: String?
    }

    private struct EntriesResponse: Decodable {
        let contentEntry: [FileEntry]
    }

    private struct LossyElement<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) {
            value = try? Value(from: decoder)
        }
    }

    enum ClientError: LocalizedError {
        case httpError(Int)
        case apiError(Int)
        case responseTooLarge(Int64)

        var errorDescription: String? {
            switch self {
            case .httpError(let code):
                return "Assembly64 returned HTTP \(code)."
            case .apiError(let code):
                return code == 463
                    ? "Assembly64 rejected the search query."
                    : "Assembly64 error \(code)."
            case .responseTooLarge(let bytes):
                return "Assembly64 archive is too large to inspect safely (\(bytes) bytes)."
            }
        }
    }

    /// AQL search, paged. Query syntax: space-separated `key:value` terms,
    /// e.g. `name:turrican category:games year:1990 sort:name order:asc`.
    func search(query: String, offset: Int = 0, limit: Int = 100) async throws -> [SearchResult] {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("search/aql/\(offset)/\(limit)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        let data = try await getData(components.url!)
        return try Self.decodeSearchResults(data)
    }

    /// Native Assembly64 chart lists, used by the desktop client as
    /// `/leet/charts/{demos|games|graphics|music|onefiledemos|tools}`.
    func chart(_ chartType: String) async throws -> [SearchResult] {
        let allowed = [
            "demos", "games", "graphics", "music", "onefiledemos", "tools",
        ]
        guard allowed.contains(chartType) else {
            throw ClientError.apiError(463)
        }
        return try await get(
            Self.baseURL.appendingPathComponent("charts/\(chartType)"))
    }

    static func decodeSearchResults(_ data: Data) throws -> [SearchResult] {
        try JSONDecoder()
            .decode([LossyElement<SearchResult>].self, from: data)
            .compactMap(\.value)
    }

    /// Files inside one library item (an item can hold several disk sides,
    /// versions, etc.).
    func entries(itemID: String, categoryID: Int) async throws -> [FileEntry] {
        let url = Self.baseURL.appendingPathComponent("search/entries/\(itemID)/\(categoryID)")
        let response: EntriesResponse = try await get(url)
        return response.contentEntry
    }

    /// Download one file's raw bytes.
    func download(itemID: String, categoryID: Int, fileID: Int) async throws -> Data {
        let url = Self.baseURL.appendingPathComponent("search/bin/\(itemID)/\(categoryID)/\(fileID)")
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.clientID, forHTTPHeaderField: "client-id")
        let (temporaryURL, response) = try await URLSession.shared.download(
            for: request)
        try validate(
            response,
            maximumBytes: Self.maximumIndividualDownloadBytes)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: temporaryURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount <= Self.maximumIndividualDownloadBytes else {
            throw ClientError.responseTooLarge(byteCount)
        }
        return try Data(
            contentsOf: temporaryURL,
            options: .mappedIfSafe)
    }

    /// Download every file belonging to an entry as one ZIP archive.
    func downloadArchive(itemID: String, categoryID: Int) async throws -> Data {
        let url = Self.baseURL.appendingPathComponent(
            "search/zip/\(itemID)/\(categoryID)")
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.clientID, forHTTPHeaderField: "client-id")
        let (temporaryURL, response) = try await URLSession.shared.download(
            for: request)
        try validate(response, maximumBytes: Self.maximumArchiveBytes)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: temporaryURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount <= Self.maximumArchiveBytes else {
            throw ClientError.responseTooLarge(byteCount)
        }
        return try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
    }

    func categories() async throws -> [Category] {
        try await get(Self.baseURL.appendingPathComponent("search/categories"))
    }

    func presets() async throws -> [AQLPreset] {
        try await get(Self.baseURL.appendingPathComponent("search/aql/presets"))
    }

    func metadata(itemID: String, categoryID: Int) async throws -> Metadata {
        try await get(Self.baseURL.appendingPathComponent(
            "metadata/\(itemID)/\(categoryID)"))
    }

    // MARK: - Plumbing

    private func getData(
        _ url: URL,
        maximumBytes: Int64? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.clientID, forHTTPHeaderField: "client-id")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, maximumBytes: maximumBytes)
        // The API reports errors as 200s with {"errorCode": N} bodies.
        if data.count < 200,
           let error = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
            throw ClientError.apiError(error.errorCode)
        }
        if let maximumBytes, Int64(data.count) > maximumBytes {
            throw ClientError.responseTooLarge(Int64(data.count))
        }
        return data
    }

    private func validate(_ response: URLResponse,
                          maximumBytes: Int64? = nil) throws {
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ClientError.httpError(http.statusCode)
        }
        if let maximumBytes,
           response.expectedContentLength > maximumBytes {
            throw ClientError.responseTooLarge(response.expectedContentLength)
        }
    }

    private struct APIErrorBody: Decodable {
        let errorCode: Int
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let data = try await getData(url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
