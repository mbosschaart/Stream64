import Foundation
import Combine

struct TransferReference: Codable, Hashable {
    let endpoint: FileEndpoint
    let path: ManagedPath
    let isDirectory: Bool
    let size: Int64?
}

enum TransferOperation: Codable, Hashable {
    case copy(source: TransferReference, destination: TransferReference)
    case move(source: TransferReference, destination: TransferReference)
    case rename(source: TransferReference, destination: TransferReference)
    case delete(target: TransferReference)
    case makeDirectory(target: TransferReference)
}

struct TransferJob: Identifiable, Codable, Hashable {
    enum State: String, Codable {
        case queued, preparing, running, paused
        case conflict, completed, failed, cancelled
    }

    let id: UUID
    let operation: TransferOperation
    var conflictPolicy: FileConflictPolicy
    let createdAt: Date
    var state: State
    var completedBytes: Int64
    var totalBytes: Int64?
    var errorMessage: String?

    init(
        operation: TransferOperation,
        conflictPolicy: FileConflictPolicy = .ask
    ) {
        id = UUID()
        self.operation = operation
        self.conflictPolicy = conflictPolicy
        createdAt = Date()
        state = .queued
        completedBytes = 0
        totalBytes = nil
        errorMessage = nil
    }
}

@MainActor
final class TransferQueue: ObservableObject {
    typealias Processor = @Sendable (
        TransferJob,
        @escaping FileProgressHandler
    ) async throws -> Void

    @Published private(set) var jobs: [TransferJob] = []
    @Published private(set) var isPaused = false

    private let storeURL: URL
    private var processor: Processor?
    private var worker: Task<Void, Never>?
    private var activeJobID: UUID?

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL
        load()
    }

    func configure(processor: @escaping Processor) {
        self.processor = processor
        startWorkerIfNeeded()
    }

    func enqueue(
        _ operation: TransferOperation,
        conflictPolicy: FileConflictPolicy = .ask
    ) {
        jobs.append(TransferJob(
            operation: operation, conflictPolicy: conflictPolicy))
        save()
        startWorkerIfNeeded()
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        startWorkerIfNeeded()
    }

    func cancel(_ id: UUID) {
        if activeJobID == id {
            worker?.cancel()
        } else {
            update(id) {
                $0.state = .cancelled
                $0.errorMessage = nil
            }
        }
    }

    func retry(_ id: UUID) {
        update(id) {
            $0.state = .queued
            $0.completedBytes = 0
            $0.errorMessage = nil
        }
        startWorkerIfNeeded()
    }

    func resolveConflict(_ id: UUID, policy: FileConflictPolicy) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .conflict else { return }
        if policy == .ask {
            jobs[index].state = .cancelled
        } else {
            jobs[index].conflictPolicy = policy
            jobs[index].state = .queued
            jobs[index].completedBytes = 0
            jobs[index].errorMessage = nil
        }
        save()
        startWorkerIfNeeded()
    }

    func remove(_ id: UUID) {
        guard activeJobID != id else { return }
        jobs.removeAll { $0.id == id }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        jobs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func clearCompleted() {
        jobs.removeAll {
            [.completed, .cancelled].contains($0.state)
        }
        save()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !isPaused, processor != nil,
              jobs.contains(where: { $0.state == .queued }) else { return }
        worker = Task { [weak self] in
            await self?.runNext()
        }
    }

    private func runNext() async {
        guard !isPaused,
              let index = jobs.firstIndex(where: { $0.state == .queued }),
              let processor else {
            worker = nil
            return
        }
        let id = jobs[index].id
        activeJobID = id
        jobs[index].state = .preparing
        jobs[index].errorMessage = nil
        save()
        let job = jobs[index]
        jobs[index].state = .running

        do {
            try await processor(job) { [weak self] completed, total in
                await MainActor.run {
                    self?.update(id) {
                        $0.completedBytes = completed
                        $0.totalBytes = total
                    }
                }
            }
            if Task.isCancelled {
                update(id) { $0.state = .cancelled }
            } else {
                update(id) {
                    $0.state = .completed
                    $0.errorMessage = nil
                }
            }
        } catch let error as FileSystemError {
            if case .conflict = error {
                update(id) {
                    $0.state = .conflict
                    $0.errorMessage = error.localizedDescription
                }
            } else {
                update(id) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
        } catch is CancellationError {
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) {
                $0.state = .failed
                $0.errorMessage = error.localizedDescription
            }
        }

        activeJobID = nil
        worker = nil
        startWorkerIfNeeded()
    }

    private func update(_ id: UUID, _ change: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              var decoded = try? JSONDecoder().decode(
                [TransferJob].self, from: data) else { return }
        for index in decoded.indices
        where [.preparing, .running].contains(decoded[index].state) {
            decoded[index].state = .queued
            decoded[index].errorMessage = "Interrupted; ready to retry."
        }
        jobs = decoded
    }

    private func save() {
        let directory = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static var defaultStoreURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent(
            "Stream64/transfer-queue.json")
    }
}
