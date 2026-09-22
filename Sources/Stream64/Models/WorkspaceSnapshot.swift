import Foundation
import AppKit
import CoreGraphics

/// One open window remembered across a full app quit/relaunch.
struct WorkspaceWindowEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case mainViewer
        case help
        case assembly64
        case fileManager
        case hvsc
        case sidRadio
        case driveBay
        case ultimateConfig
        case memoryConsole
        case debugTrace
        case telnetMonitor
        case pictureControls
        case sidOscilloscope
    }

    var kind: Kind
    var frame: CGRect
    var deviceID: UUID?
    /// SID Oscilloscope visualization mode raw value.
    var sidMode: String?
    var isMiniaturized: Bool
    var isFullScreen: Bool

    init(
        kind: Kind,
        frame: CGRect,
        deviceID: UUID? = nil,
        sidMode: String? = nil,
        isMiniaturized: Bool = false,
        isFullScreen: Bool = false
    ) {
        self.kind = kind
        self.frame = frame
        self.deviceID = deviceID
        self.sidMode = sidMode
        self.isMiniaturized = isMiniaturized
        self.isFullScreen = isFullScreen
    }

    /// Stable identity for upsert/remove (kind + optional device + SID mode).
    var identityKey: String {
        let device = deviceID?.uuidString ?? "-"
        let mode = sidMode ?? "-"
        return "\(kind.rawValue)|\(device)|\(mode)"
    }

    func matchesIdentity(
        kind: Kind,
        deviceID: UUID? = nil,
        sidMode: String? = nil
    ) -> Bool {
        self.kind == kind
            && self.deviceID == deviceID
            && self.sidMode == sidMode
    }
}

struct WorkspaceSnapshot: Codable, Equatable {
    var entries: [WorkspaceWindowEntry]
    var savedAt: Date
}

/// Live workspace persistence: updated on open/move/close, restored at launch.
enum WorkspaceSnapshotStore {
    private static let key = "workspaceSnapshot.v1"
    /// In-memory cache so upsert/remove operations don't decode UserDefaults
    /// on every window move or resize event.
    private static var cachedSnapshot: WorkspaceSnapshot?

    /// While true, main-viewer upsert/update are ignored so launch defaults
    /// cannot poison the store. Tool windows may still upsert. Removes are
    /// still allowed (except during termination).
    private(set) static var isRestoring = false

    /// While true, closes must not strip entries — quit closes every window
    /// after the backup snapshot is written.
    private(set) static var isTerminating = false

    static func beginRestore() {
        isRestoring = true
    }

    static func endRestore() {
        isRestoring = false
    }

    static func beginTermination() {
        isTerminating = true
    }

    /// Test-only: clear restore/termination gates between cases.
    static func resetSessionFlagsForTests() {
        isRestoring = false
        isTerminating = false
    }

    static func save(_ snapshot: WorkspaceSnapshot) {
        cachedSnapshot = snapshot
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> WorkspaceSnapshot? {
        if let cached = cachedSnapshot { return cached }
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(
                WorkspaceSnapshot.self, from: data)
        else { return nil }
        cachedSnapshot = snapshot
        return snapshot
    }

    static func clear() {
        cachedSnapshot = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Launch-default frames for the main viewer must not overwrite a saved
    /// size; tool windows are safe (and necessary) to record immediately.
    private static func shouldIgnoreWrite(for kind: WorkspaceWindowEntry.Kind) -> Bool {
        isRestoring && kind == .mainViewer
    }

    static func upsert(_ entry: WorkspaceWindowEntry) {
        guard !shouldIgnoreWrite(for: entry.kind) else { return }
        var snapshot = load() ?? WorkspaceSnapshot(entries: [], savedAt: Date())
        snapshot.entries.removeAll { $0.identityKey == entry.identityKey }
        snapshot.entries.append(entry)
        snapshot.savedAt = Date()
        save(snapshot)
        if entry.kind == .mainViewer {
            MainViewerFrameStore.save(.init(
                frame: entry.frame,
                isMiniaturized: entry.isMiniaturized,
                isFullScreen: entry.isFullScreen))
        }
    }

    /// Quit backup: write even while restore would normally block main-viewer.
    static func upsertForced(_ entry: WorkspaceWindowEntry) {
        var snapshot = load() ?? WorkspaceSnapshot(entries: [], savedAt: Date())
        snapshot.entries.removeAll { $0.identityKey == entry.identityKey }
        snapshot.entries.append(entry)
        snapshot.savedAt = Date()
        save(snapshot)
        if entry.kind == .mainViewer {
            MainViewerFrameStore.save(.init(
                frame: entry.frame,
                isMiniaturized: entry.isMiniaturized,
                isFullScreen: entry.isFullScreen))
        }
    }

    static func updateFrame(
        kind: WorkspaceWindowEntry.Kind,
        deviceID: UUID? = nil,
        sidMode: String? = nil,
        frame: CGRect,
        isMiniaturized: Bool,
        isFullScreen: Bool
    ) {
        guard !shouldIgnoreWrite(for: kind) else { return }
        var snapshot = load() ?? WorkspaceSnapshot(entries: [], savedAt: Date())
        if let index = snapshot.entries.firstIndex(where: {
            $0.matchesIdentity(kind: kind, deviceID: deviceID, sidMode: sidMode)
        }) {
            snapshot.entries[index].frame = frame
            snapshot.entries[index].isMiniaturized = isMiniaturized
            snapshot.entries[index].isFullScreen = isFullScreen
            snapshot.savedAt = Date()
            save(snapshot)
            if kind == .mainViewer {
                MainViewerFrameStore.save(.init(
                    frame: frame,
                    isMiniaturized: isMiniaturized,
                    isFullScreen: isFullScreen))
            }
        } else {
            upsert(WorkspaceWindowEntry(
                kind: kind,
                frame: frame,
                deviceID: deviceID,
                sidMode: sidMode,
                isMiniaturized: isMiniaturized,
                isFullScreen: isFullScreen))
        }
    }

    static func remove(
        kind: WorkspaceWindowEntry.Kind,
        deviceID: UUID? = nil,
        sidMode: String? = nil
    ) {
        // Quit closes every open tool window after the backup snapshot is
        // written; those closes must not erase the just-saved workspace.
        guard !isTerminating else { return }
        guard var snapshot = load() else { return }
        let before = snapshot.entries.count
        snapshot.entries.removeAll {
            $0.matchesIdentity(kind: kind, deviceID: deviceID, sidMode: sidMode)
        }
        guard snapshot.entries.count != before else { return }
        snapshot.savedAt = Date()
        save(snapshot)
    }
}

extension NSWindow {
    static let stream64MainViewerIdentifier = NSUserInterfaceItemIdentifier(
        "stream64.mainViewer")
    static let stream64MainViewerAutosaveName = "Stream64MainViewer"

    var stream64IsFullScreen: Bool {
        styleMask.contains(.fullScreen)
    }

    func stream64ApplyRestoredFrame(
        _ frame: CGRect,
        miniaturized: Bool,
        fullScreen: Bool
    ) {
        var target = frame
        if let screen = screen ?? NSScreen.main {
            target = Self.stream64ClampedFrame(target, to: screen.visibleFrame)
        }
        setFrame(target, display: true)
        if miniaturized, !isMiniaturized {
            miniaturize(nil)
        }
        if fullScreen, !stream64IsFullScreen {
            DispatchQueue.main.async { [weak self] in
                self?.toggleFullScreen(nil)
            }
        }
    }

    private static func stream64ClampedFrame(
        _ frame: CGRect,
        to visible: CGRect
    ) -> CGRect {
        var result = frame
        if result.width > visible.width { result.size.width = visible.width }
        if result.height > visible.height { result.size.height = visible.height }
        if result.maxX < visible.minX + 80 {
            result.origin.x = visible.minX
        }
        if result.maxY < visible.minY + 80 {
            result.origin.y = visible.minY
        }
        if result.minX > visible.maxX - 80 {
            result.origin.x = visible.maxX - result.width
        }
        if result.minY > visible.maxY - 80 {
            result.origin.y = visible.maxY - result.height
        }
        return result
    }
}

/// Dedicated persistence for the main viewer geometry (also feeds SwiftUI
/// `defaultSize` before the window exists).
enum MainViewerFrameStore {
    private static let key = "mainViewerFrame.v1"

    struct Snapshot: Codable, Equatable {
        var frame: CGRect
        var isMiniaturized: Bool
        var isFullScreen: Bool
    }

    static func save(_ snapshot: Snapshot) {
        guard snapshot.frame.width >= 900, snapshot.frame.height >= 400,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func save(from window: NSWindow) {
        save(Snapshot(
            frame: window.frame,
            isMiniaturized: window.isMiniaturized,
            isFullScreen: window.stream64IsFullScreen))
    }

    static func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    static var preferredSize: CGSize {
        if let frame = load()?.frame {
            return frame.size
        }
        return CGSize(width: 1100, height: 720)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Observes move/resize on an AppKit tool window and keeps the workspace
/// snapshot in sync. Controllers retain this for the window's lifetime.
@MainActor
final class WorkspaceWindowTracker: NSObject {
    let kind: WorkspaceWindowEntry.Kind
    let deviceID: UUID?
    let sidMode: String?

    private weak var window: NSWindow?
    private var moveObserver: NSObjectProtocol?
    private var endLiveResizeObserver: NSObjectProtocol?
    private var persistWorkItem: DispatchWorkItem?
    private var removesOnClose: Bool
    private var upsertOnAttach: Bool

    init(
        kind: WorkspaceWindowEntry.Kind,
        deviceID: UUID? = nil,
        sidMode: String? = nil,
        removesOnClose: Bool = true,
        upsertOnAttach: Bool = true
    ) {
        self.kind = kind
        self.deviceID = deviceID
        self.sidMode = sidMode
        self.removesOnClose = removesOnClose
        self.upsertOnAttach = upsertOnAttach
        super.init()
    }

    func attach(to window: NSWindow) {
        detach()
        self.window = window
        if upsertOnAttach {
            upsertFromWindow()
        }
        endLiveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.upsertFromWindow() }
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleUpsert() }
        }
    }

    func noteClosed() {
        if removesOnClose {
            WorkspaceSnapshotStore.remove(
                kind: kind, deviceID: deviceID, sidMode: sidMode)
        }
        detach()
    }

    func upsertFromWindow() {
        guard let window else { return }
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: kind,
            frame: window.frame,
            deviceID: deviceID,
            sidMode: sidMode,
            isMiniaturized: window.isMiniaturized,
            isFullScreen: window.stream64IsFullScreen))
    }

    private func scheduleUpsert() {
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.upsertFromWindow() }
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func detach() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let endLiveResizeObserver {
            NotificationCenter.default.removeObserver(endLiveResizeObserver)
        }
        moveObserver = nil
        endLiveResizeObserver = nil
        window = nil
    }

    deinit {
        // Observers must be removed; snapshot remove already done via noteClosed.
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let endLiveResizeObserver {
            NotificationCenter.default.removeObserver(endLiveResizeObserver)
        }
    }
}
