import AppKit
import Foundation

extension Notification.Name {
    /// Posted during workspace restore when Help should reopen.
    /// `object` is an `NSValue` boxing the saved `NSRect`, or `nil`.
    static let restoreHelpWindowRequested = Notification.Name(
        "restoreHelpWindowRequested")
}

/// Captures / restores Stream64 windows. Live geometry is maintained by
/// `WorkspaceSnapshotStore` + `WorkspaceWindowTracker`; quit capture is backup.
@MainActor
enum WorkspaceRestorer {
    private static var didRestoreThisLaunch = false
    private static var hasCapturedThisTermination = false
    private static var mainViewerRestoreDeadline: Date?

    static var isRestoring: Bool {
        WorkspaceSnapshotStore.isRestoring || isRestoringMainViewerFrame
    }

    static var isRestoringMainViewerFrame: Bool {
        guard let deadline = mainViewerRestoreDeadline else { return false }
        return Date() <= deadline
    }

    static func cancelMainViewerFrameRestore() {
        mainViewerRestoreDeadline = nil
    }

    /// Synchronous quit backup. Safe to call more than once per termination.
    static func captureAndSave(preferringMainViewer mainViewer: NSWindow? = nil) {
        // Freeze removes first so windowWillClose during quit cannot wipe
        // the snapshot we are about to write (or already wrote).
        WorkspaceSnapshotStore.beginTermination()
        guard !hasCapturedThisTermination else { return }
        hasCapturedThisTermination = true

        // Never rebuild the snapshot from scratch at quit — a partial live
        // capture would erase tool windows that continuous upsert already
        // recorded. Only refresh geometry for windows we can still see.
        if let mainViewer {
            MainViewerFrameStore.save(from: mainViewer)
            WorkspaceSnapshotStore.upsertForced(entry(
                kind: .mainViewer, window: mainViewer))
        } else if let window = findMainViewerWindow() {
            MainViewerFrameStore.save(from: window)
            WorkspaceSnapshotStore.upsertForced(entry(
                kind: .mainViewer, window: window))
        }

        for live in captureOpenWindows() where live.kind != .mainViewer {
            WorkspaceSnapshotStore.upsertForced(live)
        }
    }

    /// Reopen the live workspace snapshot after the splash handoff.
    static func restoreIfNeeded(
        deviceStore: DeviceStore,
        settings: AppSettings,
        sessionManager: SessionManager
    ) {
        guard !didRestoreThisLaunch else { return }
        didRestoreThisLaunch = true

        WorkspaceSnapshotStore.beginRestore()
        defer {
            // End restore after frame retries settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                WorkspaceSnapshotStore.endRestore()
                mainViewerRestoreDeadline = nil
            }
        }

        guard let snapshot = WorkspaceSnapshotStore.load(),
              !snapshot.entries.isEmpty else {
            restoreMainViewerGeometry(from: nil)
            return
        }

        func session(for deviceID: UUID) -> DeviceSession? {
            guard let device = deviceStore.devices.first(where: {
                $0.id == deviceID
            }) else { return nil }
            return sessionManager.session(for: device, settings: settings)
        }

        var sidByDevice: [UUID: [SIDWindowLayoutEntry]] = [:]
        var mainViewerEntry: WorkspaceWindowEntry?

        for entry in snapshot.entries {
            switch entry.kind {
            case .mainViewer:
                mainViewerEntry = entry

            case .help:
                let boxed = NSValue(rect: entry.frame)
                NotificationCenter.default.post(
                    name: .restoreHelpWindowRequested, object: boxed)

            case .assembly64:
                Stream64ToolWindows.showAssembly64(frame: entry.frame)
                applyChrome(entry, titled: "Assembly64")

            case .fileManager:
                Stream64ToolWindows.showFileManager(frame: entry.frame)
                applyChrome(entry, titled: "File Manager")

            case .hvsc:
                Stream64ToolWindows.showHVSC(frame: entry.frame)
                applyChrome(entry, titled: "HVSC Browser")

            case .sidRadio:
                Stream64ToolWindows.showSIDRadio(frame: entry.frame)
                applyChrome(entry, titled: "SID Station")

            case .driveBay:
                guard let deviceID = entry.deviceID,
                      let session = session(for: deviceID) else { continue }
                DriveBayWindowController.show(
                    session: session, frame: entry.frame)
                applyChrome(entry, toDeviceWindow: session.device.name,
                            suffix: "Drive Bay")

            case .ultimateConfig:
                guard let deviceID = entry.deviceID,
                      let session = session(for: deviceID) else { continue }
                UltimateConfigWindowController.show(
                    session: session, frame: entry.frame)
                applyChrome(entry, toDeviceWindow: session.device.name,
                            suffix: "Config")

            case .memoryConsole:
                guard let deviceID = entry.deviceID,
                      let session = session(for: deviceID) else { continue }
                MemoryConsoleWindowController.show(
                    session: session, frame: entry.frame)
                applyChrome(entry, toDeviceWindow: session.device.name,
                            suffix: "Memory Console")

            case .debugTrace:
                guard let deviceID = entry.deviceID,
                      let session = session(for: deviceID) else { continue }
                DebugTraceWindowController.show(
                    session: session, frame: entry.frame)
                applyChrome(entry, toDeviceWindow: session.device.name,
                            suffix: "Debug Trace")

            case .telnetMonitor:
                guard let deviceID = entry.deviceID,
                      let session = session(for: deviceID) else { continue }
                TelnetMonitorWindowController.show(
                    session: session, frame: entry.frame)
                applyChrome(entry, toDeviceWindow: session.device.name,
                            suffix: "Ultimate Menu")

            case .pictureControls:
                guard let deviceID = entry.deviceID else { continue }
                PictureControlsPanelController.show(
                    display: DisplaySettings.shared(for: deviceID),
                    frame: entry.frame)
                applyChrome(entry, titled: "Picture Controls")

            case .sidOscilloscope:
                guard let deviceID = entry.deviceID,
                      let mode = entry.sidMode else { continue }
                sidByDevice[deviceID, default: []].append(
                    SIDWindowLayoutEntry(mode: mode, frame: entry.frame))
            }
        }

        restoreMainViewerGeometry(from: mainViewerEntry)

        for (deviceID, entries) in sidByDevice {
            guard let session = session(for: deviceID), !entries.isEmpty else {
                continue
            }
            SIDOscilloscopeWindowController.restoreLayout(
                entries, session: session)
        }
    }

    /// Apply saved main-viewer geometry (after splash / on attach).
    static func applySavedMainViewerFrameIfPossible() {
        guard let snapshot = MainViewerFrameStore.load()
                ?? WorkspaceSnapshotStore.load()?.entries
                .first(where: { $0.kind == .mainViewer })
                .map({ MainViewerFrameStore.Snapshot(
                    frame: $0.frame,
                    isMiniaturized: $0.isMiniaturized,
                    isFullScreen: $0.isFullScreen) }),
              let window = findMainViewerWindow()
        else { return }
        if mainViewerRestoreDeadline == nil || !isRestoringMainViewerFrame {
            mainViewerRestoreDeadline = Date().addingTimeInterval(2.5)
        }
        window.stream64ApplyRestoredFrame(
            snapshot.frame,
            miniaturized: snapshot.isMiniaturized,
            fullScreen: snapshot.isFullScreen)
    }

    private static func restoreMainViewerGeometry(
        from entry: WorkspaceWindowEntry?
    ) {
        let snapshot = entry.map {
            MainViewerFrameStore.Snapshot(
                frame: $0.frame,
                isMiniaturized: $0.isMiniaturized,
                isFullScreen: $0.isFullScreen)
        } ?? MainViewerFrameStore.load()
        guard let snapshot else { return }
        MainViewerFrameStore.save(snapshot)
        mainViewerRestoreDeadline = Date().addingTimeInterval(2.5)

        let delays: [TimeInterval] = [0, 0.05, 0.15, 0.35, 0.7, 1.2, 2.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard isRestoringMainViewerFrame,
                      let window = findMainViewerWindow() else { return }
                let frame = window.frame
                let alreadyMatched =
                    abs(frame.width - snapshot.frame.width) < 1.5
                    && abs(frame.height - snapshot.frame.height) < 1.5
                if alreadyMatched { return }
                // macOS sets the .fullScreen styleMask bit at the START of the
                // fullscreen animation (500–900ms before it completes). Once that
                // bit is set, any further toggleFullScreen call will exit
                // fullscreen, undoing the previous one. Skip retries that would
                // otherwise fire mid-animation and cancel the transition.
                if snapshot.isFullScreen && window.stream64IsFullScreen { return }
                window.stream64ApplyRestoredFrame(
                    snapshot.frame,
                    miniaturized: snapshot.isMiniaturized,
                    fullScreen: snapshot.isFullScreen)
            }
        }
    }

    static func findMainViewerWindow() -> NSWindow? {
        if let tagged = NSApp.windows.first(where: {
            $0.identifier == NSWindow.stream64MainViewerIdentifier
        }) {
            return tagged
        }
        let toolTitles: Set<String> = [
            "Assembly64", "File Manager", "HVSC Browser", "SID Station",
            "Stream64 Help", "About Stream64", "Picture Controls",
        ]
        return NSApp.windows.first { window in
            guard window.canBecomeMain else { return false }
            if toolTitles.contains(window.title) { return false }
            if window.title.hasSuffix(" Drive Bay")
                || window.title.hasSuffix(" Config")
                || window.title.hasSuffix(" Memory Console")
                || window.title.hasSuffix(" Debug Trace")
                || window.title.hasSuffix(" Ultimate Menu")
                || window.title.hasSuffix(" Menu")
            {
                return false
            }
            return true
        }
    }

    private static func applyChrome(
        _ entry: WorkspaceWindowEntry,
        titled title: String
    ) {
        guard let window = NSApp.windows.first(where: { $0.title == title })
        else { return }
        window.stream64ApplyRestoredFrame(
            entry.frame,
            miniaturized: entry.isMiniaturized,
            fullScreen: entry.isFullScreen)
    }

    private static func applyChrome(
        _ entry: WorkspaceWindowEntry,
        toDeviceWindow deviceName: String,
        suffix: String
    ) {
        applyChrome(entry, titled: "\(deviceName) \(suffix)")
    }

    private static func captureOpenWindows() -> [WorkspaceWindowEntry] {
        var entries: [WorkspaceWindowEntry] = []

        if let window = findMainViewerWindow() {
            entries.append(entry(kind: .mainViewer, window: window))
        }

        if let help = NSApp.windows.first(where: {
            $0.title == "Stream64 Help"
        }) {
            entries.append(entry(kind: .help, window: help))
        }

        entries += Stream64ToolWindows.captureOpenWindows()
        entries += DriveBayWindowController.captureOpenWindows()
        entries += UltimateConfigWindowController.captureOpenWindows()
        entries += MemoryConsoleWindowController.captureOpenWindows()
        entries += DebugTraceWindowController.captureOpenWindows()
        entries += TelnetMonitorWindowController.captureOpenWindows()
        entries += PictureControlsPanelController.captureOpenWindows()
        entries += SIDOscilloscopeWindowController.captureOpenWindows()

        return entries
    }

    static func entry(
        kind: WorkspaceWindowEntry.Kind,
        window: NSWindow,
        deviceID: UUID? = nil,
        sidMode: String? = nil
    ) -> WorkspaceWindowEntry {
        WorkspaceWindowEntry(
            kind: kind,
            frame: window.frame,
            deviceID: deviceID,
            sidMode: sidMode,
            isMiniaturized: window.isMiniaturized,
            isFullScreen: window.stream64IsFullScreen)
    }
}
