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

    struct Category: Decodable, Identifiable, Hashable {
        let id: Int
        let name: String
        let description: String?
        let groupingName: String?
        let type: String?
    }

    struct AQLPreset: Decodable, Hashable {
        let type: String
        let description: String
        let values: [AQLPresetValue]
    }

    struct AQLPresetValue: Decodable, Hashable {
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
            guard let url, let candidate = URL(string: url),
                  candidate.scheme != nil else { return nil }
            return candidate
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
            if let direct = URL(string: path), direct.scheme != nil {
                return direct
            }
            if let target, let base = URL(string: target), base.scheme != nil {
                return base.appendingPathComponent(path)
            }
            if path.hasPrefix("/") {
                return URL(string: "https://hackerswithstyle.se\(path)")
            }
            return Assembly64Client.baseURL.appendingPathComponent(path)
        }
    }

    struct TargetAndPath: Codable, Hashable {
        let path: String?
        let target: String?
    }

    private struct EntriesResponse: Decodable {
        let contentEntry: [FileEntry]
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
        return try await get(components.url!)
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
        return try await getData(url)
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

    private func getData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.clientID, forHTTPHeaderField: "client-id")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        // The API reports errors as 200s with {"errorCode": N} bodies.
        if data.count < 200,
           let error = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
            throw ClientError.apiError(error.errorCode)
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
