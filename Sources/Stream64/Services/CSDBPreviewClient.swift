import Foundation

/// Minimal CSDB fallback used only when Assembly64 metadata has no preview or
/// source link. Category provenance must be `type == "csdb"` before calling.
struct CSDBPreviewClient {
    struct Preview: Codable, Hashable {
        let sourceURL: URL
        let imageURL: URL?
    }

    enum ClientError: LocalizedError {
        case invalidURL
        case httpError(Int)
        case invalidXML

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Could not build the CSDB preview URL."
            case .httpError(let code): return "CSDB returned HTTP \(code)."
            case .invalidXML: return "CSDB returned unreadable preview metadata."
            }
        }
    }

    func preview(releaseID: String) async throws -> Preview {
        var components = URLComponents(string: "https://csdb.dk/webservice/")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "depth", value: "1"),
            URLQueryItem(name: "id", value: releaseID),
        ]
        guard let url = components.url else {
            throw ClientError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ClientError.httpError(http.statusCode)
        }
        return try Self.parse(data: data, releaseID: releaseID)
    }

    static func parse(data: Data, releaseID: String) throws -> Preview {
        guard data.count <= 2 * 1024 * 1024,
              let sourceURL = URL(
                string: "https://csdb.dk/release/?id=\(releaseID)") else {
            throw ClientError.invalidXML
        }
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ClientError.invalidXML }

        let imageURL = delegate.screenshot.flatMap(Self.validWebURL)
        return Preview(sourceURL: sourceURL, imageURL: imageURL)
    }

    private static func validWebURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        return url
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var screenshot: String?
        private var collectingScreenshot = false
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if elementName.caseInsensitiveCompare("ScreenShot") == .orderedSame {
                collectingScreenshot = true
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collectingScreenshot { buffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            guard collectingScreenshot,
                  elementName.caseInsensitiveCompare("ScreenShot") == .orderedSame else {
                return
            }
            collectingScreenshot = false
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { screenshot = value }
        }
    }
}
