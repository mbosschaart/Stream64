import Foundation

actor FileOperationCoordinator {
    typealias DeviceResolver = @Sendable (UUID) async -> UltimateDevice?

    private let local = LocalFileSystemProvider()
    private let deviceResolver: DeviceResolver
    typealias DriveInspector = @Sendable (UltimateDevice) async throws -> [UltimateAPIClient.DriveInfo]
    private let inspectDrives: DriveInspector

    init(deviceResolver: @escaping DeviceResolver,
         inspectDrives: @escaping DriveInspector = { try await UltimateAPIClient(device: $0).fetchDrives() }) {
        self.deviceResolver = deviceResolver
        self.inspectDrives = inspectDrives
    }

    func process(
        _ job: TransferJob,
        progress: @escaping FileProgressHandler
    ) async throws {
        // Inspect current hardware state for every mutation, including jobs
        // that were queued before an image was mounted. Read failures stop the
        // operation; a stale or unavailable drive snapshot is not permission.
        let mutations: [TransferReference]
        switch job.operation {
        case .copy(_, let destination): mutations = [destination]
        case .move(let source, let destination), .rename(let source, let destination): mutations = [source, destination]
        case .delete(let target), .makeDirectory(let target): mutations = [target]
        }
        for reference in mutations {
            if case .ultimate(let id) = reference.endpoint {
                guard let device = await deviceResolver(id) else { throw FileSystemError.notConnected }
                try MountedImageProtection.validateMutation(reference.path, drives: await inspectDrives(device))
            }
        }
        switch job.operation {
        case .copy(let source, let destination):
            try validateWritableDestination(destination)
            let copied = try await copy(
                source, destination, policy: job.conflictPolicy,
                progress: progress)
            if copied && job.includesTitleSettings == true {
                _ = try await copyCompanion(source, destination, job: job, progress: progress)
            }
        case .move(let source, let destination):
            try validateWritableDestination(destination)
            try validateMutableSource(source)
            if source.endpoint == destination.endpoint, job.includesTitleSettings != true,
               try await provider(for: destination.endpoint).item(
                    destination.path) == nil {
                try await provider(for: source.endpoint).rename(
                    source.path, to: destination.path)
            } else {
                let copiedEverything = try await copy(
                    source, destination, policy: job.conflictPolicy,
                    progress: progress)
                // A skipped destination is a successful no-op for Copy, but
                // it must never authorize Move to delete the source. For a
                // directory, preserve the complete source tree if any child
                // was skipped; this may leave already-copied duplicates, but
                // never destroys uncopied data.
                let companionCopied = job.includesTitleSettings == true && copiedEverything
                    ? try await copyCompanion(source, destination, job: job, progress: progress) : true
                if copiedEverything && companionCopied {
                    try await checkMounted(source.path, endpoint: source.endpoint)
                    try await provider(for: source.endpoint).delete(
                        source.path, recursive: true)
                    if job.includesTitleSettings == true, TitleSettingsProfile.isTitle(source.path.name), !source.isDirectory {
                        let companion = TitleSettingsProfile.companionPath(for: source.path)
                        if try await provider(for: source.endpoint).item(companion) != nil {
                            try await provider(for: source.endpoint).delete(companion, recursive: false)
                        }
                    }
                }
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

    private func checkMounted(_ path: ManagedPath, endpoint: FileEndpoint) async throws {
        if case .ultimate(let id) = endpoint {
            guard let device = await deviceResolver(id) else { throw FileSystemError.notConnected }
            try MountedImageProtection.validateMutation(path, drives: await inspectDrives(device))
        }
    }

    private func copyCompanion(_ source: TransferReference, _ destination: TransferReference,
                               job: TransferJob, progress: @escaping FileProgressHandler) async throws -> Bool {
        guard !source.isDirectory, TitleSettingsProfile.isTitle(source.path.name) else { return true }
        let sourcePath = TitleSettingsProfile.companionPath(for: source.path)
        guard let item = try await provider(for: source.endpoint).item(sourcePath) else { return true }
        let destinationPath = TitleSettingsProfile.companionPath(for: destination.path)
        if case .ultimate(let id) = destination.endpoint {
            guard let device = await deviceResolver(id) else { throw FileSystemError.notConnected }
            try MountedImageProtection.validateMutation(destinationPath, drives: await inspectDrives(device))
        }
        return try await copy(.init(endpoint: source.endpoint, path: sourcePath, isDirectory: false, size: item.size),
            .init(endpoint: destination.endpoint, path: destinationPath, isDirectory: false, size: item.size),
            policy: job.conflictPolicy, progress: progress)
    }

    private func copy(
        _ source: TransferReference,
        _ requestedDestination: TransferReference,
        policy: FileConflictPolicy,
        progress: @escaping FileProgressHandler
    ) async throws -> Bool {
        try Task.checkCancellation()
        let sourceProvider = try await provider(for: source.endpoint)
        let destinationProvider = try await provider(
            for: requestedDestination.endpoint)
        if source.endpoint == .local,
           let sourceItem = try await sourceProvider.item(source.path),
           sourceItem.kind == .symlink {
            throw FileSystemError.unsupported(
                "Symbolic links cannot be transferred.")
        }
        guard let destinationPath = try await resolvedDestination(
            requestedDestination.path, provider: destinationProvider,
            policy: policy) else { return false }
        guard !destinationPath.rawValue.hasPrefix(
            source.path.rawValue + "/"
        ) || source.endpoint != requestedDestination.endpoint else {
            throw FileSystemError.unsafePath
        }

        try await checkMounted(destinationPath, endpoint: requestedDestination.endpoint)
        if source.isDirectory {
            if try await destinationProvider.item(destinationPath) == nil {
                try await destinationProvider.makeDirectory(destinationPath)
            }
            var copiedEverything = true
            for child in try await sourceProvider.list(source.path) {
                let childSource = TransferReference(
                    endpoint: source.endpoint, path: child.path,
                    isDirectory: child.isDirectory, size: child.size)
                let childDestination = TransferReference(
                    endpoint: requestedDestination.endpoint,
                    path: destinationPath.appending(child.name),
                    isDirectory: child.isDirectory, size: child.size)
                let copied = try await copy(
                    childSource, childDestination, policy: policy,
                    progress: progress)
                copiedEverything = copiedEverything && copied
            }
            return copiedEverything
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
        do {
            try await destinationProvider.upload(
                localPart, to: destinationPart, progress: progress)
        } catch {
            // A failed network upload can leave a partial remote object.
            // Remove it before propagating the error so retries do not
            // accumulate orphaned transfer files.
            try? await destinationProvider.delete(
                destinationPart, recursive: true)
            throw error
        }
        let backupPath = destinationPath.parent.appending(
            ".stream64-backup-\(UUID().uuidString)")
        var backupCreated = false
        do {
            try await checkMounted(destinationPath, endpoint: requestedDestination.endpoint)
            if try await destinationProvider.item(destinationPath) != nil {
                // Preserve the original until promotion succeeds. Deleting
                // first made a network/rename failure destructive.
                try await destinationProvider.rename(
                    destinationPath, to: backupPath)
                backupCreated = true
            }
            try await destinationProvider.rename(
                destinationPart, to: destinationPath)
            if backupCreated {
                try? await destinationProvider.delete(
                    backupPath, recursive: true)
            }
        } catch {
            // Promotion may fail after the upload has completed. The part
            // must still be removed, while the original is restored below.
            try? await destinationProvider.delete(
                destinationPart, recursive: true)
            if backupCreated {
                try? await destinationProvider.delete(
                    destinationPath, recursive: true)
                try? await destinationProvider.rename(
                    backupPath, to: destinationPath)
            }
            throw error
        }
        return true
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
