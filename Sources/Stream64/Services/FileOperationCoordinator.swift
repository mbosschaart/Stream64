import Foundation

actor FileOperationCoordinator {
    typealias DeviceResolver = @Sendable (UUID) async -> UltimateDevice?

    private let local = LocalFileSystemProvider()
    private let deviceResolver: DeviceResolver

    init(deviceResolver: @escaping DeviceResolver) {
        self.deviceResolver = deviceResolver
    }

    func process(
        _ job: TransferJob,
        progress: @escaping FileProgressHandler
    ) async throws {
        switch job.operation {
        case .copy(let source, let destination):
            try validateWritableDestination(destination)
            try await copy(
                source, destination, policy: job.conflictPolicy,
                progress: progress)
        case .move(let source, let destination):
            try validateWritableDestination(destination)
            try validateMutableSource(source)
            if source.endpoint == destination.endpoint,
               try await provider(for: destination.endpoint).item(
                    destination.path) == nil {
                try await provider(for: source.endpoint).rename(
                    source.path, to: destination.path)
            } else {
                try await copy(
                    source, destination, policy: job.conflictPolicy,
                    progress: progress)
                try await provider(for: source.endpoint).delete(
                    source.path, recursive: true)
            }
        case .rename(let source, let destination):
            try validateMutableSource(source)
            try validateWritableDestination(destination)
            try await provider(for: source.endpoint).rename(
                source.path, to: destination.path)
        case .delete(let target):
            try validateMutableSource(target)
            guard target.path.rawValue != "/" else {
                throw FileSystemError.unsafePath
            }
            try await provider(for: target.endpoint).delete(
                target.path, recursive: true)
        case .makeDirectory(let target):
            try validateWritableDestination(target)
            try await provider(for: target.endpoint).makeDirectory(target.path)
        }
    }

    private func copy(
        _ source: TransferReference,
        _ requestedDestination: TransferReference,
        policy: FileConflictPolicy,
        progress: @escaping FileProgressHandler
    ) async throws {
        try Task.checkCancellation()
        let sourceProvider = try await provider(for: source.endpoint)
        let destinationProvider = try await provider(
            for: requestedDestination.endpoint)
        guard let destinationPath = try await resolvedDestination(
            requestedDestination.path, provider: destinationProvider,
            policy: policy) else { return }
        guard !destinationPath.rawValue.hasPrefix(
            source.path.rawValue + "/"
        ) || source.endpoint != requestedDestination.endpoint else {
            throw FileSystemError.unsafePath
        }

        if source.isDirectory {
            if try await destinationProvider.item(destinationPath) == nil {
                try await destinationProvider.makeDirectory(destinationPath)
            }
            for child in try await sourceProvider.list(source.path) {
                let childSource = TransferReference(
                    endpoint: source.endpoint, path: child.path,
                    isDirectory: child.isDirectory, size: child.size)
                let childDestination = TransferReference(
                    endpoint: requestedDestination.endpoint,
                    path: destinationPath.appending(child.name),
                    isDirectory: child.isDirectory, size: child.size)
                try await copy(
                    childSource, childDestination, policy: policy,
                    progress: progress)
            }
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stream64Transfers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
        let localPart = temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: localPart) }

        try await sourceProvider.download(
            source.path, to: localPart, progress: progress)

        let partName = ".stream64-part-\(UUID().uuidString)"
        let destinationPart = destinationPath.parent.appending(partName)
        if try await destinationProvider.item(destinationPart) != nil {
            try await destinationProvider.delete(
                destinationPart, recursive: true)
        }
        try await destinationProvider.upload(
            localPart, to: destinationPart, progress: progress)
        if try await destinationProvider.item(destinationPath) != nil {
            try await destinationProvider.delete(
                destinationPath, recursive: true)
        }
        try await destinationProvider.rename(
            destinationPart, to: destinationPath)
    }

    private func resolvedDestination(
        _ requested: ManagedPath,
        provider: any FileSystemProvider,
        policy: FileConflictPolicy
    ) async throws -> ManagedPath? {
        guard try await provider.item(requested) != nil else {
            return requested
        }
        switch policy {
        case .ask:
            throw FileSystemError.conflict(requested.name)
        case .skip:
            return nil
        case .replace:
            return requested
        case .keepBoth:
            let base = (requested.name as NSString).deletingPathExtension
            let ext = (requested.name as NSString).pathExtension
            for number in 2...999 {
                let suffix = ext.isEmpty
                    ? "\(base) \(number)"
                    : "\(base) \(number).\(ext)"
                let candidate = requested.parent.appending(suffix)
                if try await provider.item(candidate) == nil {
                    return candidate
                }
            }
            throw FileSystemError.conflict(requested.name)
        }
    }

    private func provider(
        for endpoint: FileEndpoint
    ) async throws -> any FileSystemProvider {
        switch endpoint {
        case .local:
            return local
        case .ultimate(let id):
            guard let device = await deviceResolver(id) else {
                throw FileSystemError.notConnected
            }
            return UltimateFileSystemProvider(device: device)
        }
    }

    private func validateWritableDestination(
        _ reference: TransferReference
    ) throws {
        if case .ultimate = reference.endpoint,
           reference.path.parent.rawValue == "/" {
            throw FileSystemError.unsupported(
                "Choose an Ultimate storage drive before creating or "
                    + "uploading items")
        }
    }

    private func validateMutableSource(
        _ reference: TransferReference
    ) throws {
        if case .ultimate = reference.endpoint,
           reference.path.parent.rawValue == "/" {
            throw FileSystemError.unsupported(
                "Ultimate storage roots cannot be renamed, moved, or deleted")
        }
    }
}
