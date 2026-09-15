import AppKit
import SwiftUI

/// AppKit-hosted tool windows (same pattern as Ultimate Config / Drive Bay).
///
/// SwiftUI `Window` scenes use a private `NSWindow` subclass whose own
/// `toggleFullScreen:` bypasses the `NSWindow` swizzle, so they promote into
/// the viewer's Space. Plain `NSWindow` controllers get a real Mission
/// Control Space like Ultimate Config.
@MainActor
enum Stream64ToolWindows {
    private static var assembly64Controller: Assembly64WindowController?
    private static var hvscController: HVSCWindowController?
    private static var sidRadioController: SIDRadioWindowController?
    private static var fileManagerController: FileManagerWindowController?

    private static var deviceStore: DeviceStore?
    private static var settings: AppSettings?
    private static var sessionManager: SessionManager?
    private static var assembly64Library: Assembly64LibraryStore?
    private static var hvscLibrary: HVSCLibraryStore?
    private static var localHVSCLibrary: HVSCLocalLibrary?
    private static var sidFlowRecommendations: SIDFlowRecommendationStore?

    static func configure(
        deviceStore: DeviceStore,
        settings: AppSettings,
        sessionManager: SessionManager,
        assembly64Library: Assembly64LibraryStore,
        hvscLibrary: HVSCLibraryStore,
        localHVSCLibrary: HVSCLocalLibrary,
        sidFlowRecommendations: SIDFlowRecommendationStore
    ) {
        self.deviceStore = deviceStore
        self.settings = settings
        self.sessionManager = sessionManager
        self.assembly64Library = assembly64Library
        self.hvscLibrary = hvscLibrary
        self.localHVSCLibrary = localHVSCLibrary
        self.sidFlowRecommendations = sidFlowRecommendations
    }

    static func showAssembly64(frame: NSRect? = nil) {
        guard let deviceStore, let settings, let sessionManager,
              let assembly64Library else { return }
        if let existing = assembly64Controller {
            if let frame {
                existing.window?.setFrame(frame, display: true)
            }
            existing.syncWorkspaceEntry()
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = Assembly64WindowController(
            deviceStore: deviceStore,
            settings: settings,
            library: assembly64Library,
            sessionProvider: { device in
                sessionManager.session(for: device, settings: settings)
            }
        )
        assembly64Controller = controller
        if let frame {
            controller.window?.setFrame(frame, display: false)
        }
        controller.showWindow(nil)
        controller.syncWorkspaceEntry()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showFileManager(frame: NSRect? = nil) {
        guard let deviceStore, let settings, let sessionManager else { return }
        if let existing = fileManagerController {
            if let frame {
                existing.window?.setFrame(frame, display: true)
            }
            existing.syncWorkspaceEntry()
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = FileManagerWindowController(
            deviceStore: deviceStore,
            settings: settings,
            sessionManager: sessionManager
        )
        fileManagerController = controller
        if let frame {
            controller.window?.setFrame(frame, display: false)
        }
        controller.showWindow(nil)
        controller.syncWorkspaceEntry()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showHVSC(frame: NSRect? = nil) {
        guard let deviceStore, let settings, let sessionManager,
              let hvscLibrary, let localHVSCLibrary, let sidFlowRecommendations else { return }
        if let existing = hvscController {
            if let frame {
                existing.window?.setFrame(frame, display: true)
            }
            existing.syncWorkspaceEntry()
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = HVSCWindowController(
            deviceStore: deviceStore,
            settings: settings,
            library: hvscLibrary,
            localLibrary: localHVSCLibrary,
            sidFlowRecommendations: sidFlowRecommendations,
            sessionProvider: { device in
                sessionManager.session(for: device, settings: settings)
            }
        )
        hvscController = controller
        if let frame {
            controller.window?.setFrame(frame, display: false)
        }
        controller.showWindow(nil)
        controller.syncWorkspaceEntry()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showSIDRadio(frame: NSRect? = nil) {
        guard let deviceStore, let settings, let sessionManager,
              let sidFlowRecommendations, let hvscLibrary, let localHVSCLibrary else { return }
        if let existing = sidRadioController {
            if let frame {
                existing.window?.setFrame(frame, display: true)
            }
            existing.syncWorkspaceEntry()
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SIDRadioWindowController(
            deviceStore: deviceStore,
            settings: settings,
            store: sidFlowRecommendations,
            library: hvscLibrary,
            localLibrary: localHVSCLibrary,
            sessionProvider: { device in
                sessionManager.session(for: device, settings: settings)
            })
        sidRadioController = controller
        if let frame {
            controller.window?.setFrame(frame, display: false)
        }
        controller.showWindow(nil)
        controller.syncWorkspaceEntry()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func captureOpenWindows() -> [WorkspaceWindowEntry] {
        var entries: [WorkspaceWindowEntry] = []
        if let window = assembly64Controller?.window {
            entries.append(WorkspaceRestorer.entry(
                kind: .assembly64, window: window))
        }
        if let window = fileManagerController?.window {
            entries.append(WorkspaceRestorer.entry(
                kind: .fileManager, window: window))
        }
        if let window = hvscController?.window {
            entries.append(WorkspaceRestorer.entry(
                kind: .hvsc, window: window))
        }
        if let window = sidRadioController?.window {
            entries.append(WorkspaceRestorer.entry(
                kind: .sidRadio, window: window))
        }
        return entries
    }

    fileprivate static func assembly64DidClose() {
        assembly64Controller = nil
    }

    fileprivate static func hvscDidClose() {
        hvscController = nil
    }

    fileprivate static func sidRadioDidClose() {
        sidRadioController = nil
    }

    fileprivate static func fileManagerDidClose() {
        fileManagerController = nil
    }
}

@MainActor
final class Assembly64WindowController: NSWindowController, NSWindowDelegate {
    private let deviceStore: DeviceStore
    private let settings: AppSettings
    private let library: Assembly64LibraryStore
    private let sessionProvider: (UltimateDevice) -> DeviceSession
    private let workspaceTracker = WorkspaceWindowTracker(kind: .assembly64)

    init(
        deviceStore: DeviceStore,
        settings: AppSettings,
        library: Assembly64LibraryStore,
        sessionProvider: @escaping (UltimateDevice) -> DeviceSession
    ) {
        self.deviceStore = deviceStore
        self.settings = settings
        self.library = library
        self.sessionProvider = sessionProvider
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Assembly64"
        window.minSize = NSSize(width: 900, height: 680)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: NavigationStack {
                Assembly64View(sessionProvider: sessionProvider)
                    .environmentObject(deviceStore)
                    .environmentObject(settings)
                    .environmentObject(library)
            })
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
        workspaceTracker.attach(to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func syncWorkspaceEntry() {
        workspaceTracker.upsertFromWindow()
    }

    func windowWillClose(_ notification: Notification) {
        workspaceTracker.noteClosed()
        Stream64ToolWindows.assembly64DidClose()
    }
}

@MainActor
final class HVSCWindowController: NSWindowController, NSWindowDelegate {
    private let workspaceTracker = WorkspaceWindowTracker(kind: .hvsc)

    init(
        deviceStore: DeviceStore,
        settings: AppSettings,
        library: HVSCLibraryStore,
        localLibrary: HVSCLocalLibrary,
        sidFlowRecommendations: SIDFlowRecommendationStore,
        sessionProvider: @escaping (UltimateDevice) -> DeviceSession
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "HVSC Browser"
        window.minSize = NSSize(width: 880, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: NavigationStack {
                HVSCView(sessionProvider: sessionProvider)
                    .environmentObject(deviceStore)
                    .environmentObject(settings)
                    .environmentObject(library)
                    .environmentObject(localLibrary)
                    .environmentObject(sidFlowRecommendations)
            })
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
        workspaceTracker.attach(to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func syncWorkspaceEntry() {
        workspaceTracker.upsertFromWindow()
    }

    func windowWillClose(_ notification: Notification) {
        workspaceTracker.noteClosed()
        Stream64ToolWindows.hvscDidClose()
    }
}

@MainActor
final class SIDRadioWindowController: NSWindowController, NSWindowDelegate {
    private let workspaceTracker = WorkspaceWindowTracker(kind: .sidRadio)

    init(
        deviceStore: DeviceStore,
        settings: AppSettings,
        store: SIDFlowRecommendationStore,
        library: HVSCLibraryStore,
        localLibrary: HVSCLocalLibrary,
        sessionProvider: @escaping (UltimateDevice) -> DeviceSession
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "SID Station"
        window.minSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: NavigationStack {
                SIDRadioView(sessionProvider: sessionProvider)
                    .environmentObject(deviceStore)
                    .environmentObject(settings)
                    .environmentObject(store)
                    .environmentObject(library)
                    .environmentObject(localLibrary)
            })
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
        workspaceTracker.attach(to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func syncWorkspaceEntry() {
        workspaceTracker.upsertFromWindow()
    }

    func windowWillClose(_ notification: Notification) {
        workspaceTracker.noteClosed()
        Stream64ToolWindows.sidRadioDidClose()
    }
}

@MainActor
final class FileManagerWindowController: NSWindowController, NSWindowDelegate {
    private let workspaceTracker = WorkspaceWindowTracker(kind: .fileManager)

    init(
        deviceStore: DeviceStore,
        settings: AppSettings,
        sessionManager: SessionManager
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "File Manager"
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: NavigationStack {
                RemoteBrowserView()
                    .environmentObject(deviceStore)
                    .environmentObject(settings)
                    .environmentObject(sessionManager)
            })
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
        workspaceTracker.attach(to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func syncWorkspaceEntry() {
        workspaceTracker.upsertFromWindow()
    }

    func windowWillClose(_ notification: Notification) {
        workspaceTracker.noteClosed()
        Stream64ToolWindows.fileManagerDidClose()
    }
}
