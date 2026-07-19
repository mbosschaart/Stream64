import Foundation

/// Client for the Assembly64 online library (hackerswithstyle.se/leet) —
/// AQL search, item file listings, and binary downloads.
///
/// The API requires a registered `client-id` header on every request;
/// unknown IDs are rejected with errorCode 464.
struct Assembly64Client {
    static let baseURL = URL(string: "https://hackerswithstyle.se/leet")!
    static let clientID = "assembly64"

    struct SearchResult: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let category: Int
        let group: String?
        let handle: String?
        let year: Int?
        let rating: Int?
        let released: String?

        var displayGroup: String {
            let g = (group ?? "").replacingOccurrences(of: "_", with: " ")
            return g.isEmpty ? (handle ?? "") : g
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

    private struct EntriesResponse: Decodable {
        let contentEntry: [FileEntry]
    }

    enum ClientError: LocalizedError {
        case httpError(Int)
        case apiError(Int)

        var errorDescription: String? {
            switch self {
            case .httpError(let code):
                return "Assembly64 returned HTTP \(code)."
            case .apiError(let code):
                return code == 463
                    ? "Assembly64 rejected the search query."
                    : "Assembly64 error \(code)."
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

    func categories() async throws -> [Category] {
        try await get(Self.baseURL.appendingPathComponent("search/categories"))
    }

    // MARK: - Plumbing

    private func getData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.clientID, forHTTPHeaderField: "client-id")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.httpError(http.statusCode)
        }
        // The API reports errors as 200s with {"errorCode": N} bodies.
        if data.count < 200,
           let error = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
            throw ClientError.apiError(error.errorCode)
        }
        return data
    }

    private struct APIErrorBody: Decodable {
        let errorCode: Int
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let data = try await getData(url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
