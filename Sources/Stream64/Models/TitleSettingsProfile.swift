import Foundation

struct TitleSettingsProfile: Equatable {
    var values: [String: [String: String]]
    static let maximumBytes = 64 * 1024

    init(values: [String: [String: String]]) { self.values = values }

    init(data: Data) throws {
        guard data.count <= Self.maximumBytes, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw FileSystemError.invalidResponse("Settings must be UTF-8 text under 64 KiB")
        }
        var result: [String: [String: String]] = [:]
        var section: String?
        for raw in text.components(separatedBy: .newlines) {
            guard raw.utf8.count < 320 else { throw FileSystemError.invalidResponse("Settings line exceeds firmware limit") }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains("[") && !name.contains("]") else { throw FileSystemError.invalidResponse("Invalid settings section") }
                section = name
                continue
            }
            guard let section, let equals = line.firstIndex(of: "=") else { throw FileSystemError.invalidResponse("Expected [category] then Item=Value") }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, result[section]?[key] == nil else { throw FileSystemError.invalidResponse("Empty or duplicate settings item") }
            result[section, default: [:]][key] = value
        }
        values = result
    }

    var data: Data {
        Data(values.keys.sorted().map { category in
            "[\(category)]\n" + values[category]!.keys.sorted().map { "\($0)=\(values[category]![$0]!)\n" }.joined()
        }.joined(separator: "\n").utf8)
    }

    static func isTitle(_ name: String) -> Bool {
        ["prg", "p00", "d64", "d71", "d81", "g64", "g71", "crt", "tap", "dnp"].contains((name as NSString).pathExtension.lowercased())
    }

    static func companionPath(for path: ManagedPath) -> ManagedPath {
        ManagedPath((path.rawValue as NSString).deletingPathExtension + ".cfg")
    }
}
