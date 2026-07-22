import Foundation

actor LocalFileSystemProvider: FileSystemProvider {
    let endpoint: FileEndpoint = .local
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func list(_ path: ManagedPath) async throws -> [FilesystemItem] {
        let url = URL(fileURLWithPath: path.rawValue, isDirectory: true)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .isHiddenKey,
        ]
        return try fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: []
        ).compactMap { child in
            let values = try child.resourceValues(forKeys: Set(keys))
            let directory = values.isDirectory == true
            return FilesystemItem(
                endpoint: .local,
                path: ManagedPath(child.path),
                kind: .classify(
                    name: child.lastPathComponent,
                    isDirectory: directory,
                    isSymbolicLink: values.isSymbolicLink == true),
                size: directory ? nil : Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate)
        }
    }

    func item(_ path: ManagedPath) async throws -> FilesystemItem? {
        let url = URL(fileURLWithPath: path.rawValue)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey,
        ])
        let directory = values.isDirectory == true
        return FilesystemItem(
            endpoint: .local, path: path,
            kind: .classify(name: path.name, isDirectory: directory,
                            isSymbolicLink: values.isSymbolicLink == true),
            size: directory ? nil : Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate)
    }

    func makeDirectory(_ path: ManagedPath) async throws {
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: path.rawValue, isDirectory: true),
            withIntermediateDirectories: false)
    }

    func rename(_ source: ManagedPath, to destination: ManagedPath) async throws {
        try fileManager.moveItem(
            at: URL(fileURLWithPath: source.rawValue),
            to: URL(fileURLWithPath: destination.rawValue))
    }

    func delete(_ path: ManagedPath, recursive: Bool) async throws {
        let url = URL(fileURLWithPath: path.rawValue)
        if !recursive,
           (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           !(try fileManager.contentsOfDirectory(atPath: url.path)).isEmpty {
            throw FileSystemError.conflict(path.name)
        }
        try fileManager.removeItem(at: url)
    }

    func download(_ source: ManagedPath, to localURL: URL,
                  progress: @escaping FileProgressHandler) async throws {
        let sourceURL = URL(fileURLWithPath: source.rawValue)
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        try fileManager.copyItem(at: sourceURL, to: localURL)
        let size = Int64(values.fileSize ?? 0)
        await progress(size, size)
    }

    func upload(_ localURL: URL, to destination: ManagedPath,
                progress: @escaping FileProgressHandler) async throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        try fileManager.copyItem(
            at: localURL, to: URL(fileURLWithPath: destination.rawValue))
        let size = Int64(values.fileSize ?? 0)
        await progress(size, size)
    }
}
