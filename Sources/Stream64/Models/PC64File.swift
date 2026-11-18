import Foundation

/// PC64 wraps a C64 file in a 26-byte header. Only P00 contains a runnable PRG.
struct PC64File: Equatable {
    let name: String
    let payload: Data
    let kind: String

    init(data: Data, filename: String) throws {
        let kind = (filename as NSString).pathExtension.lowercased()
        guard ["p00", "s00", "u00", "r00"].contains(kind), data.count >= 26,
              Array(data.prefix(8)) == Array("C64File\0".utf8) else {
            throw FileSystemError.invalidResponse("Invalid PC64 header")
        }
        let bytes = data.dropFirst(8).prefix(17).prefix { $0 != 0 }
        let name = bytes.map { byte -> Character in
            let value = byte == 0xA0 ? 32 : (byte >= 0xC1 && byte <= 0xDA ? byte - 128 : byte)
            return Character(UnicodeScalar(value))
        }
        self.name = String(name).trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        payload = Data(data.dropFirst(26))
        if kind == "p00", (data[data.startIndex + 25] != 0 || payload.count < 2) {
            throw FileSystemError.invalidResponse("P00 has no valid PRG payload")
        }
    }

    func programData() throws -> Data {
        guard kind == "p00" else { throw FileSystemError.unsupported("Running a \(kind.uppercased()) file") }
        return payload
    }
}
