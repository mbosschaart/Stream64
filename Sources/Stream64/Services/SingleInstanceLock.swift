import AppKit
import Foundation
import Darwin

/// Process-wide advisory lock preventing multiple `swift run` / app launches
/// from binding the same UDP ports. A stale lock file is harmless: `flock`
/// belongs to the process and is released automatically on exit/crash.
final class SingleInstanceLock {
    enum Acquisition {
        case acquired
        case alreadyRunning(pid: pid_t?)
    }

    private let lockURL: URL
    private var descriptor: Int32 = -1

    init(lockURL: URL? = nil) {
        self.lockURL = lockURL ?? Self.defaultLockURL
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    func acquire() -> Acquisition {
        guard descriptor < 0 else { return .acquired }

        let fd = lockURL.path.withCString {
            open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else {
            // If the lock cannot be created, fail open rather than making the
            // viewer unusable because Application Support is unavailable.
            return .acquired
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return .alreadyRunning(pid: existingPID())
        }

        descriptor = fd
        let value = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = value.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        fsync(fd)
        return .acquired
    }

    private func existingPID() -> pid_t? {
        guard let value = try? String(contentsOf: lockURL, encoding: .utf8),
              let raw = Int32(value.trimmingCharacters(
                in: .whitespacesAndNewlines)),
              raw > 0 else {
            return nil
        }
        return pid_t(raw)
    }

    private static var defaultLockURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(
            "Stream64", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("instance.lock")
    }
}
