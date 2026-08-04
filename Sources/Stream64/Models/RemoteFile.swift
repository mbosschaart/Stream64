import Foundation

enum FileEndpoint: Hashable, Codable, Identifiable {
    case local
    case ultimate(UUID)

    var id: String {
        switch self {
        case .local: return "local"
        case .ultimate(let id): return "ultimate:\(id.uuidString)"
        }
    }
}

struct ManagedPath: Hashable, Codable, CustomStringConvertible {
    let rawValue: String

    init(_ value: String) {
        let standardized = NSString(string: value).standardizingPath
        rawValue = standardized.isEmpty ? "/" : standardized
    }

    var description: String { rawValue }
    var name: String {
        rawValue == "/" ? "/" : (rawValue as NSString).lastPathComponent
    }
    var parent: ManagedPath {
        guard rawValue != "/" else { return self }
        return ManagedPath((rawValue as NSString).deletingLastPathComponent)
    }

    func appending(_ component: String) -> ManagedPath {
        ManagedPath((rawValue as NSString).appendingPathComponent(component))
    }

    static func validatedRemote(_ value: String) throws -> ManagedPath {
        guard !value.contains("\r"), !value.contains("\n"),
              !value.contains("\0") else {
            throw FileSystemError.unsafePath
        }
        let path = ManagedPath(value.hasPrefix("/") ? value : "/\(value)")
        guard path.rawValue.hasPrefix("/"), !path.rawValue.contains("/../") else {
            throw FileSystemError.unsafePath
        }
        return path
    }
}

enum ManagedFileKind: String, Codable {
    case directory, symlink, prg, disk, sid, mod, crt, zip, regular

    static func classify(name: String, isDirectory: Bool, isSymbolicLink: Bool = false) -> Self {
        if isSymbolicLink { return .symlink }
        if isDirectory { return .directory }
        switch (name as NSString).pathExtension.lowercased() {
        case "prg": return .prg
        case "d64", "g64", "d71", "g71", "d81": return .disk
        case "sid": return .sid
        case "mod": return .mod
        case "crt": return .crt
        case "zip": return .zip
        default: return .regular
        }
    }

    var supportsDeviceAction: Bool {
        [.prg, .disk, .sid, .mod, .crt].contains(self)
    }
}

struct FilesystemItem: Identifiable, Hashable, Codable {
    let endpoint: FileEndpoint
    let path: ManagedPath
    let kind: ManagedFileKind
    let size: Int64?
    let modified: Date?

    var id: String { "\(endpoint.id):\(path.rawValue)" }
    var name: String { path.name }
    var isDirectory: Bool { kind == .directory }
    var fileExtension: String {
        isDirectory ? "" : (name as NSString).pathExtension.lowercased()
    }
}

enum FileConflictPolicy: String, Codable, CaseIterable {
    case ask, replace, skip, keepBoth
}

enum FileSystemError: LocalizedError, Equatable {
    case unsafePath
    case unsupported(String)
    case notConnected
    case ftpServiceUnavailable
    case invalidResponse(String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .unsafePath: return "The path is unsafe."
        case .unsupported(let operation): return "\(operation) is not supported here."
        case .notConnected: return "The filesystem is not connected."
        case .ftpServiceUnavailable:
            return "The Ultimate FTP service is unavailable. Enable FTP File Service in Network Services."
        case .invalidResponse(let response): return "Invalid FTP response: \(response)"
        case .conflict(let name): return "An item named \(name) already exists."
        }
    }
}

typealias FileProgressHandler = (_ completed: Int64, _ total: Int64?) async -> Void

protocol FileSystemProvider: Sendable {
    var endpoint: FileEndpoint { get }
    func list(_ path: ManagedPath) async throws -> [FilesystemItem]
    func item(_ path: ManagedPath) async throws -> FilesystemItem?
    func makeDirectory(_ path: ManagedPath) async throws
    func rename(_ source: ManagedPath, to destination: ManagedPath) async throws
    func delete(_ path: ManagedPath, recursive: Bool) async throws
    func download(_ source: ManagedPath, to localURL: URL,
                  progress: @escaping FileProgressHandler) async throws
    func upload(_ localURL: URL, to destination: ManagedPath,
                progress: @escaping FileProgressHandler) async throws
}
