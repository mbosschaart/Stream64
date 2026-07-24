import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let stream64FileItem = UTType(
        exportedAs: "net.bosschaart.Stream64.file-item")
}

private struct FileDragPayload: Codable, Transferable {
    let reference: TransferReference

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .stream64FileItem)
    }
}

private enum PaneContextAction: Equatable {
    case open, rename, copy, move, newFolder, delete
    case deviceAction, mountAndRun
}

@MainActor
final class FilePaneModel: ObservableObject, Identifiable {
    enum Location: Hashable, Identifiable {
        case local
        case ultimate(UUID)

        var id: String {
            switch self {
            case .local: return "local"
            case .ultimate(let id): return "ultimate:\(id.uuidString)"
            }
        }
    }

    let id = UUID()
    @Published var location: Location
    @Published var path: ManagedPath
    @Published var pathText: String
    @Published var items: [FilesystemItem] = []
    @Published var selection: Set<String> = []
    @Published var markedIDs: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showHidden = false
    @Published var sortOrder = [KeyPathComparator(\FilesystemItem.name)]
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()

    init(location: Location, path: ManagedPath) {
        self.location = location
        self.path = path
        pathText = path.rawValue
    }

    var selectedItems: [FilesystemItem] {
        let effectiveSelection = markedIDs.isEmpty ? selection : markedIDs
        return items.filter { effectiveSelection.contains($0.id) }
    }

    func changeLocation(
        _ location: Location,
        devices: [UltimateDevice]
    ) {
        self.location = location
        switch location {
        case .local:
            path = ManagedPath(
                FileManager.default.homeDirectoryForCurrentUser.path)
        case .ultimate:
            path = ManagedPath("/")
        }
        pathText = path.rawValue
        selection = []
        markedIDs = []
        refresh(devices: devices)
    }

    func navigate(to path: ManagedPath, devices: [UltimateDevice]) {
        self.path = path
        pathText = path.rawValue
        selection = []
        markedIDs = []
        refresh(devices: devices)
    }

    func refresh(devices: [UltimateDevice]) {
        refreshTask?.cancel()
        let currentGeneration = UUID()
        generation = currentGeneration
        isLoading = true
        errorMessage = nil
        let endpoint = location
        let path = path
        refreshTask = Task {
            do {
                let provider: any FileSystemProvider
                switch endpoint {
                case .local:
                    provider = LocalFileSystemProvider()
                case .ultimate(let id):
                    let device = devices.first { $0.id == id }
                    guard let device else { throw FileSystemError.notConnected }
                    provider = UltimateFileSystemProvider(device: device)
                }
                var result = try await provider.list(path)
                guard !Task.isCancelled, generation == currentGeneration else { return }
                if !showHidden {
                    result.removeAll { $0.name.hasPrefix(".") }
                }
                result.sort {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                items = result
                selection = selection.intersection(Set(result.map(\.id)))
                markedIDs = markedIDs.intersection(Set(result.map(\.id)))
                isLoading = false
            } catch {
                guard generation == currentGeneration else { return }
                items = []
                selection = []
                markedIDs = []
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func endpoint() -> FileEndpoint? {
        switch location {
        case .local: return .local
        case .ultimate(let id): return .ultimate(id)
        }
    }

    func toggleMarkAtCursor() {
        guard let id = selection.first,
              let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        toggleMark(id)
        if index + 1 < items.count {
            selection = [items[index + 1].id]
        }
    }

    func toggleMark(_ id: String) {
        if markedIDs.contains(id) {
            markedIDs.remove(id)
        } else {
            markedIDs.insert(id)
        }
    }

    func clearMarks() {
        markedIDs = []
    }
}

struct RemoteBrowserView: View {
    @EnvironmentObject private var deviceStore: DeviceStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessionManager: SessionManager
    @StateObject private var left = FilePaneModel(
        location: .local,
        path: ManagedPath(FileManager.default.homeDirectoryForCurrentUser.path))
    @StateObject private var right = FilePaneModel(
        location: .local, path: ManagedPath("/"))
    @StateObject private var transferQueue = TransferQueue()
    @State private var activePaneID: UUID?
    @State private var coordinator: FileOperationCoordinator?
    @State private var actionTarget: DeviceActionTarget?
    @State private var queueExpanded = true
    @State private var pendingTransfer: (move: Bool, items: [FilesystemItem])?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var folderName = ""
    @State private var showingNewFolder = false
    @State private var showingDelete = false
    @State private var operationError: String?
    @State private var conflictJobID: UUID?
    @State private var keyMonitor: Any?

    private var activePane: FilePaneModel {
        activePaneID == right.id ? right : left
    }
    private var destinationPane: FilePaneModel {
        activePaneID == right.id ? left : right
    }
    private var selectedDevice: UltimateDevice? {
        deviceStore.selectedDevice
    }

    private var actionTargetDevices: [UltimateDevice] {
        switch actionTarget {
        case .device(let id):
            return deviceStore.devices.filter { $0.id == id }
        case .allConnected:
            return deviceStore.devices.filter {
                sessionManager.session(
                    for: $0, settings: settings).isConnected
            }
        case nil:
            return selectedDevice.map { [$0] } ?? []
        }
    }

    var body: some View {
        browserBase
        .confirmationDialog(
            pendingTransfer?.move == true ? "Move selected items?" : "Copy selected items?",
            isPresented: Binding(
                get: { pendingTransfer != nil },
                set: { if !$0 { pendingTransfer = nil } })
        ) {
            Button("Replace Existing") { enqueuePending(policy: .replace) }
            Button("Skip Existing") { enqueuePending(policy: .skip) }
            Button("Keep Both") { enqueuePending(policy: .keepBoth) }
            Button("Cancel", role: .cancel) { pendingTransfer = nil }
        } message: {
            Text("Choose how name conflicts should be handled.")
        }
        .alert("Rename", isPresented: $showingRename) {
            TextField("New name", text: $renameText)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Folder name", text: $folderName)
            Button("Create") { performNewFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete selected items?",
            isPresented: $showingDelete
        ) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .alert(
            "An item already exists",
            isPresented: Binding(
                get: { conflictJobID != nil },
                set: {
                    if !$0, let id = conflictJobID {
                        transferQueue.resolveConflict(id, policy: .ask)
                        conflictJobID = nil
                    }
                })
        ) {
            Button("Replace") { resolveQueuedConflict(.replace) }
            Button("Skip") { resolveQueuedConflict(.skip) }
            Button("Keep Both") { resolveQueuedConflict(.keepBoth) }
            Button("Cancel Transfer", role: .destructive) {
                resolveQueuedConflict(.ask)
            }
        } message: {
            Text("Choose what Stream64 should do with the existing item.")
        }
        .alert(
            "File Operation Failed",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } })
        ) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    private var browserBase: some View {
        VStack(spacing: 0) {
            HSplitView {
                FilePaneView(
                    model: left, devices: deviceStore.devices,
                    isActive: activePaneID != right.id,
                    activate: { activePaneID = left.id },
                    dropItems: { enqueueDrops($0, into: left) },
                    dropURLs: { enqueueURLs($0, into: left) },
                    dragProvider: makeDragProvider,
                    contextAction: {
                        handleContextAction($0, selection: $1, pane: left)
                    })
                FilePaneView(
                    model: right, devices: deviceStore.devices,
                    isActive: activePaneID == right.id,
                    activate: { activePaneID = right.id },
                    dropItems: { enqueueDrops($0, into: right) },
                    dropURLs: { enqueueURLs($0, into: right) },
                    dragProvider: makeDragProvider,
                    contextAction: {
                        handleContextAction($0, selection: $1, pane: right)
                    })
            }
            .frame(minHeight: 410)

            Divider()
            commandBar
            Divider()
            queueView
        }
        .frame(minWidth: 980, minHeight: 620)
        .navigationTitle("File Manager")
        .toolbar { browserToolbar }
        .task { configureAndRefresh() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: transferQueue.jobs.map(\.state)) {
            left.refresh(devices: deviceStore.devices)
            right.refresh(devices: deviceStore.devices)
            if conflictJobID == nil {
                conflictJobID = transferQueue.jobs.first {
                    $0.state == .conflict
                }?.id
            }
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Run Target", selection: $actionTarget) {
                ForEach(deviceStore.devices) { device in
                    Text(device.name)
                        .tag(Optional(DeviceActionTarget.device(device.id)))
                }
                Divider()
                Text("All Connected C64s")
                    .tag(Optional(DeviceActionTarget.allConnected))
            }
            .frame(maxWidth: 220)
            Button {
                swapPaneLocations()
            } label: {
                Label("Swap Panes", systemImage: "arrow.left.arrow.right")
            }
            Button {
                left.refresh(devices: deviceStore.devices)
                right.refresh(devices: deviceStore.devices)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            commandButton("F2 Rename", action: beginRename)
            commandButton(copyCommandTitle) { beginTransfer(move: false) }
            commandButton("F6 Move") { beginTransfer(move: true) }
            commandButton("F7 New Folder", action: beginNewFolder)
            commandButton("F8 Delete", action: requestDelete)
            Divider().frame(height: 22)
            Button("Run / Mount / Play") {
                performDeviceAction()
            }
                .disabled(activePane.selectedItems.count != 1
                          || !activePane.selectedItems[0].kind.supportsDeviceAction
                          || actionTargetDevices.isEmpty)
            Button("Mount & Run") {
                performDeviceAction(mountAndRun: true)
            }
            .disabled(activePane.selectedItems.count != 1
                      || activePane.selectedItems[0].kind != .disk
                      || actionTargetDevices.isEmpty)
            Spacer()
            Text("\(activePane.selectedItems.count) selected")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .padding(8)
    }

    private var copyCommandTitle: String {
        switch (activePane.location, destinationPane.location) {
        case (.local, .ultimate): return "F5 Upload"
        case (.ultimate, .local): return "F5 Download"
        default: return "F5 Copy"
        }
    }

    private func commandButton(
        _ title: String, action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .disabled(
                (title.contains("Rename") || title.contains("Copy")
                 || title.contains("Upload") || title.contains("Download")
                 || title.contains("Move") || title.contains("Delete"))
                && activePane.selectedItems.isEmpty)
    }

    private var queueView: some View {
        DisclosureGroup(isExpanded: $queueExpanded) {
            List {
                ForEach(transferQueue.jobs) { job in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(jobDescription(job))
                                .lineLimit(1)
                            if let error = job.errorMessage {
                                Text(error).font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        if job.state == .running {
                            ProgressView(
                                value: Double(job.completedBytes),
                                total: Double(max(job.totalBytes ?? 1, 1)))
                                .frame(width: 120)
                        }
                        Text(job.state.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if job.state == .failed {
                            Button("Retry") { transferQueue.retry(job.id) }
                        }
                        if job.state == .conflict {
                            Button("Resolve") { conflictJobID = job.id }
                        }
                        if [.queued, .running].contains(job.state) {
                            Button("Cancel") { transferQueue.cancel(job.id) }
                        }
                    }
                }
                .onMove(perform: transferQueue.move)
            }
            .frame(minHeight: 90, maxHeight: 180)
            HStack {
                Button(transferQueue.isPaused ? "Resume Queue" : "Pause Queue") {
                    transferQueue.isPaused ? transferQueue.resume() : transferQueue.pause()
                }
                Button("Clear Completed") { transferQueue.clearCompleted() }
                Spacer()
            }
            .padding(.horizontal, 8)
        } label: {
            Text("Transfer Queue (\(transferQueue.jobs.count))")
                .font(.headline)
        }
        .padding(8)
    }

    private func configureAndRefresh() {
        let coordinator = FileOperationCoordinator { id in
            await MainActor.run {
                deviceStore.devices.first { $0.id == id }
            }
        }
        self.coordinator = coordinator
        transferQueue.configure { job, progress in
            try await coordinator.process(job, progress: progress)
        }
        activePaneID = left.id
        if actionTarget == nil, let selectedDevice {
            actionTarget = .device(selectedDevice.id)
        }
        if let selectedDevice {
            right.location = .ultimate(selectedDevice.id)
            right.path = ManagedPath("/")
            right.pathText = "/"
        }
        left.refresh(devices: deviceStore.devices)
        right.refresh(devices: deviceStore.devices)
        installKeyMonitor()
    }

    private func beginTransfer(move: Bool) {
        let items = activePane.selectedItems
        guard !items.isEmpty else { return }
        if case .ultimate = destinationPane.location,
           destinationPane.path.rawValue == "/" {
            operationError = "Open Flash, SD, Temp, or a USB drive in the "
                + "destination pane before uploading files. The Ultimate's "
                + "top-level root is a drive list and cannot store files."
            return
        }
        let existingNames = Set(
            destinationPane.items.map { $0.name.lowercased() })
        if items.contains(where: {
            existingNames.contains($0.name.lowercased())
        }) {
            pendingTransfer = (move, items)
        } else {
            enqueue(items: items, move: move, policy: .ask)
        }
    }

    private func enqueuePending(policy: FileConflictPolicy) {
        guard let pending = pendingTransfer else { return }
        enqueue(items: pending.items, move: pending.move, policy: policy)
        pendingTransfer = nil
    }

    private func enqueue(
        items: [FilesystemItem],
        move: Bool,
        policy: FileConflictPolicy
    ) {
        guard let destinationEndpoint = destinationPane.endpoint() else {
            return
        }
        for item in items {
            let source = TransferReference(
                endpoint: item.endpoint, path: item.path,
                isDirectory: item.isDirectory, size: item.size)
            let destination = TransferReference(
                endpoint: destinationEndpoint,
                path: destinationPane.path.appending(item.name),
                isDirectory: item.isDirectory, size: item.size)
            transferQueue.enqueue(
                move
                    ? .move(source: source, destination: destination)
                    : .copy(source: source, destination: destination),
                conflictPolicy: policy)
        }
        activePane.clearMarks()
    }

    private func beginRename() {
        guard let item = activePane.selectedItems.first else { return }
        renameText = item.name
        showingRename = true
    }

    private func performRename() {
        guard let item = activePane.selectedItems.first,
              !renameText.isEmpty else { return }
        let source = TransferReference(
            endpoint: item.endpoint, path: item.path,
            isDirectory: item.isDirectory, size: item.size)
        let destination = TransferReference(
            endpoint: item.endpoint,
            path: item.path.parent.appending(renameText),
            isDirectory: item.isDirectory, size: item.size)
        transferQueue.enqueue(
            .rename(source: source, destination: destination))
    }

    private func beginNewFolder() {
        folderName = ""
        showingNewFolder = true
    }

    private func performNewFolder() {
        guard !folderName.isEmpty,
              let endpoint = activePane.endpoint() else { return }
        transferQueue.enqueue(.makeDirectory(target: TransferReference(
            endpoint: endpoint, path: activePane.path.appending(folderName),
            isDirectory: true, size: nil)))
    }

    private func performDelete() {
        for item in activePane.selectedItems {
            transferQueue.enqueue(.delete(target: TransferReference(
                endpoint: item.endpoint, path: item.path,
                isDirectory: item.isDirectory, size: item.size)))
        }
    }

    private func requestDelete() {
        guard !activePane.selectedItems.isEmpty else { return }
        if settings.confirmDestructiveActions {
            showingDelete = true
        } else {
            performDelete()
        }
    }

    private func enqueueDrops(
        _ payloads: [FileDragPayload], into pane: FilePaneModel
    ) -> Bool {
        guard let endpoint = pane.endpoint() else {
            return false
        }
        for payload in payloads {
            let destination = TransferReference(
                endpoint: endpoint,
                path: pane.path.appending(payload.reference.path.name),
                isDirectory: payload.reference.isDirectory,
                size: payload.reference.size)
            transferQueue.enqueue(
                .copy(source: payload.reference, destination: destination),
                conflictPolicy: .ask)
        }
        return !payloads.isEmpty
    }

    private func enqueueURLs(
        _ urls: [URL], into pane: FilePaneModel
    ) -> Bool {
        guard let endpoint = pane.endpoint() else {
            return false
        }
        for url in urls {
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey,
            ])
            let directory = values?.isDirectory == true
            let source = TransferReference(
                endpoint: .local, path: ManagedPath(url.path),
                isDirectory: directory,
                size: directory ? nil : Int64(values?.fileSize ?? 0))
            let destination = TransferReference(
                endpoint: endpoint,
                path: pane.path.appending(url.lastPathComponent),
                isDirectory: directory, size: source.size)
            transferQueue.enqueue(
                .copy(source: source, destination: destination),
                conflictPolicy: .ask)
        }
        return !urls.isEmpty
    }

    private func makeDragProvider(_ item: FilesystemItem) -> NSItemProvider {
        if case .local = item.endpoint {
            return NSItemProvider(
                contentsOf: URL(fileURLWithPath: item.path.rawValue))
                ?? NSItemProvider()
        }

        let provider = NSItemProvider()
        if let payload = try? JSONEncoder().encode(
            FileDragPayload(reference: TransferReference(
                endpoint: item.endpoint, path: item.path,
                isDirectory: item.isDirectory, size: item.size))
        ) {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.stream64FileItem.identifier,
                visibility: .all
            ) { completion in
                completion(payload, nil)
                return nil
            }
        }

        guard !item.isDirectory,
              case .ultimate(let deviceID) = item.endpoint,
              let device = deviceStore.devices.first(where: {
                  $0.id == deviceID
              }) else {
            return provider
        }
        let contentType = UTType(filenameExtension: item.fileExtension) ?? .data
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [], visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: item.size ?? 100)
            Task {
                do {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "Stream64Promises", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    let target = directory.appendingPathComponent(item.name)
                    try? FileManager.default.removeItem(at: target)
                    try await UltimateFTPClient(device: device).download(
                        item.path, to: target
                    ) { completed, total in
                        progress.totalUnitCount = total ?? progress.totalUnitCount
                        progress.completedUnitCount = completed
                    }
                    completion(target, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    private func resolveQueuedConflict(_ policy: FileConflictPolicy) {
        guard let id = conflictJobID else { return }
        conflictJobID = nil
        transferQueue.resolveConflict(id, policy: policy)
    }

    private func performDeviceAction(mountAndRun: Bool = false) {
        guard let item = activePane.selectedItems.first else { return }
        let targets = actionTargetDevices
        guard !targets.isEmpty else { return }
        let behavior: DeviceSession.MountBehavior =
            mountAndRun ? .mountAndRun : .mountOnly
        Task {
            // A single target can execute its own remote file directly.
            if targets.count == 1,
               case .ultimate(let sourceID) = item.endpoint,
               sourceID == targets[0].id {
                let session = sessionManager.session(
                    for: targets[0], settings: settings)
                await session.loadRemoteFile(
                    path: item.path.rawValue,
                    filename: item.name,
                    mountBehavior: behavior)
                return
            }

            do {
                let data = try await dataForDeviceAction(item)
                await withTaskGroup(of: Void.self) { group in
                    for device in targets {
                        let session = sessionManager.session(
                            for: device, settings: settings)
                        group.addTask {
                            _ = await session.loadData(
                                data, filename: item.name,
                                mountBehavior: behavior)
                        }
                    }
                }
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func dataForDeviceAction(
        _ item: FilesystemItem
    ) async throws -> Data {
        switch item.endpoint {
        case .local:
            return try Data(
                contentsOf: URL(fileURLWithPath: item.path.rawValue))
        case .ultimate(let id):
            guard let sourceDevice = deviceStore.devices.first(
                where: { $0.id == id }) else {
                throw FileSystemError.notConnected
            }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await UltimateFTPClient(device: sourceDevice).download(
                item.path, to: temporary
            ) { _, _ in }
            return try Data(contentsOf: temporary)
        }
    }

    private func swapPaneLocations() {
        let leftLocation = left.location
        let leftPath = left.path
        left.location = right.location
        left.path = right.path
        left.pathText = right.path.rawValue
        right.location = leftLocation
        right.path = leftPath
        right.pathText = leftPath.rawValue
        left.refresh(devices: deviceStore.devices)
        right.refresh(devices: deviceStore.devices)
    }

    private func jobDescription(_ job: TransferJob) -> String {
        switch job.operation {
        case .copy(let source, let destination):
            return "Copy \(source.path.name) → \(destination.path.parent)"
        case .move(let source, let destination):
            return "Move \(source.path.name) → \(destination.path.parent)"
        case .rename(let source, let destination):
            return "Rename \(source.path.name) → \(destination.path.name)"
        case .delete(let target): return "Delete \(target.path.name)"
        case .makeDirectory(let target): return "Create \(target.path.name)"
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow?.title == "File Manager" else { return event }
            if event.keyCode == 49 {
                guard !(NSApp.keyWindow?.firstResponder is NSTextView) else {
                    return event
                }
                activePane.toggleMarkAtCursor()
                return nil
            }
            switch event.keyCode {
            case 120: beginRename(); return nil       // F2
            case 96: beginTransfer(move: false); return nil // F5
            case 97: beginTransfer(move: true); return nil  // F6
            case 98: beginNewFolder(); return nil     // F7
            case 100: requestDelete(); return nil // F8
            case 36:
                if let folder = activePane.selectedItems.first,
                   folder.isDirectory {
                    activePane.navigate(
                        to: folder.path, devices: deviceStore.devices)
                    return nil
                }
                return event
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleContextAction(
        _ action: PaneContextAction,
        selection: Set<String>,
        pane: FilePaneModel
    ) {
        activePaneID = pane.id
        pane.clearMarks()
        pane.selection = selection
        if action == .open,
           let folder = pane.selectedItems.first,
           folder.isDirectory {
            pane.navigate(to: folder.path, devices: deviceStore.devices)
            return
        }

        DispatchQueue.main.async {
            switch action {
            case .open:
                break
            case .rename:
                beginRename()
            case .copy:
                beginTransfer(move: false)
            case .move:
                beginTransfer(move: true)
            case .newFolder:
                beginNewFolder()
            case .delete:
                requestDelete()
            case .deviceAction:
                performDeviceAction()
            case .mountAndRun:
                performDeviceAction(mountAndRun: true)
            }
        }
    }
}

private struct FilePaneView: View {
    @ObservedObject var model: FilePaneModel
    let devices: [UltimateDevice]
    let isActive: Bool
    let activate: () -> Void
    let dropItems: ([FileDragPayload]) -> Bool
    let dropURLs: ([URL]) -> Bool
    let dragProvider: (FilesystemItem) -> NSItemProvider
    let contextAction: (PaneContextAction, Set<String>) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Location", selection: Binding(
                    get: { model.location },
                    set: { model.changeLocation($0, devices: devices) }
                )) {
                    Text("Local Mac").tag(FilePaneModel.Location.local)
                    ForEach(devices) { device in
                        Text(device.name).tag(
                            FilePaneModel.Location.ultimate(device.id))
                    }
                }
                .labelsHidden()
                if model.location == .local {
                    Menu("Volumes") {
                        Button("Home") {
                            model.navigate(
                                to: ManagedPath(
                                    FileManager.default
                                        .homeDirectoryForCurrentUser.path),
                                devices: devices)
                        }
                        Divider()
                        ForEach(localVolumes) { volume in
                            Button(volume.name) {
                                model.navigate(
                                    to: ManagedPath(volume.url.path),
                                    devices: devices)
                            }
                        }
                    }
                }
                Button {
                    model.navigate(
                        to: model.path.parent, devices: devices)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(model.path.rawValue == "/")
                TextField("Path", text: $model.pathText)
                    .onSubmit {
                        model.navigate(
                            to: ManagedPath(model.pathText),
                            devices: devices)
                    }
                Button {
                    model.refresh(devices: devices)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button("Open") {
                    if let folder = model.selectedItems.first,
                       folder.isDirectory {
                        model.navigate(
                            to: folder.path, devices: devices)
                    }
                }
                .disabled(
                    model.selectedItems.count != 1
                    || model.selectedItems.first?.isDirectory != true)
            }
            .padding(8)

            ZStack {
                Table(
                    model.items,
                    selection: $model.selection,
                    sortOrder: $model.sortOrder
                ) {
                    TableColumn("Name", value: \.name) { item in
                        HStack {
                            Button {
                                activate()
                                model.toggleMark(item.id)
                            } label: {
                                Image(systemName:
                                    model.markedIDs.contains(item.id)
                                        ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(
                                        model.markedIDs.contains(item.id)
                                            ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Mark or unmark this item")
                            Image(systemName: item.isDirectory ? "folder" : "doc")
                                .onDrag { dragProvider(item) }
                                .help("Drag this icon to transfer the item")
                            Text(item.name)
                        }
                    }
                    TableColumn("Ext", value: \.fileExtension)
                        .width(min: 44, ideal: 55, max: 80)
                    TableColumn("Size") { item in
                        Text(item.size.map(ByteCountFormatter.string) ?? "—")
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("Modified") { item in
                        Text(item.modified?.formatted(
                            date: .abbreviated, time: .shortened) ?? "—")
                    }
                    .width(min: 120, ideal: 150)
                }
                .contextMenu(
                    forSelectionType: String.self
                ) { selection in
                    let selected = model.items.filter {
                        selection.contains($0.id)
                    }
                    if selected.count == 1, selected[0].isDirectory {
                        Button("Open") {
                            contextAction(.open, selection)
                        }
                    }
                    if selected.count == 1 {
                        Button("Rename…") {
                            contextAction(.rename, selection)
                        }
                    }
                    Button(
                        model.location == .local
                            ? "Upload / Copy to Other Pane"
                            : "Download / Copy to Other Pane"
                    ) {
                        contextAction(.copy, selection)
                    }
                    .disabled(selected.isEmpty)
                    Button("Move to Other Pane") {
                        contextAction(.move, selection)
                    }
                    .disabled(selected.isEmpty)
                    Divider()
                    Button("New Folder…") {
                        contextAction(.newFolder, selection)
                    }
                    if selected.count == 1,
                       selected[0].kind.supportsDeviceAction {
                        Button(
                            selected[0].kind == .disk
                                ? "Mount" : "Run / Play"
                        ) {
                            contextAction(.deviceAction, selection)
                        }
                        if selected[0].kind == .disk {
                            Button("Mount & Run") {
                                contextAction(.mountAndRun, selection)
                            }
                        }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        contextAction(.delete, selection)
                    }
                    .disabled(selected.isEmpty)
                } primaryAction: { selection in
                    if let folder = model.items.first(where: {
                        selection.contains($0.id) && $0.isDirectory
                    }) {
                        model.navigate(
                            to: folder.path, devices: devices)
                    }
                }
                if model.isLoading { ProgressView() }
                if let error = model.errorMessage {
                    ContentUnavailableView(
                        "Cannot Open Folder",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error))
                }
            }
            HStack {
                Text("\(model.items.count) items")
                if !model.markedIDs.isEmpty {
                    Text("· \(model.markedIDs.count) marked")
                    Button("Clear Marks") { model.clearMarks() }
                        .buttonStyle(.link)
                }
                Spacer()
                Toggle("Hidden", isOn: $model.showHidden)
                    .toggleStyle(.checkbox)
                    .onChange(of: model.showHidden) {
                        model.refresh(devices: devices)
                    }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isActive ? Color.accentColor : .clear, lineWidth: 2)
        )
        .onChange(of: model.selection) {
            if !model.selection.isEmpty { activate() }
        }
        .dropDestination(for: FileDragPayload.self) { items, _ in
            dropItems(items)
        }
        .dropDestination(for: URL.self) { urls, _ in
            dropURLs(urls)
        }
        .padding(4)
    }

    private struct LocalVolume: Identifiable {
        let url: URL
        let name: String
        var id: URL { url }
    }

    private var localVolumes: [LocalVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey]
        return (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []).compactMap { url in
                let values = try? url.resourceValues(
                    forKeys: Set(keys))
                return LocalVolume(
                    url: url,
                    name: values?.volumeName ?? url.lastPathComponent)
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }
    }
}

private extension ByteCountFormatter {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes, countStyle: .file)
    }
}
