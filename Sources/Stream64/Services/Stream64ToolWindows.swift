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
    private static var fileManagerController: FileManagerWindowController?

    private static var deviceStore: DeviceStore?
    private static var settings: AppSettings?
    private static var sessionManager: SessionManager?
    private static var assembly64Library: Assembly64LibraryStore?
    private static var hvscLibrary: HVSCLibraryStore?

    static func configure(
        deviceStore: DeviceStore,
        settings: AppSettings,
        sessionManager: SessionManager,
        assembly64Library: Assembly64LibraryStore,
        hvscLibrary: HVSCLibraryStore
    ) {
        self.deviceStore = deviceStore
        self.settings = settings
        self.sessionManager = sessionManager
        self.assembly64Library = assembly64Library
        self.hvscLibrary = hvscLibrary
    }

    static func showAssembly64() {
        guard let deviceStore, let settings, let sessionManager,
              let assembly64Library else { return }
        if let existing = assembly64Controller {
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
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showFileManager() {
        guard let deviceStore, let settings, let sessionManager else { return }
        if let existing = fileManagerController {
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
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showHVSC() {
        guard let deviceStore, let settings, let sessionManager,
              let hvscLibrary else { return }
        if let existing = hvscController {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = HVSCWindowController(
            deviceStore: deviceStore,
            settings: settings,
            library: hvscLibrary,
            sessionProvider: { device in
                sessionManager.session(for: device, settings: settings)
            }
        )
        hvscController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate static func assembly64DidClose() {
        assembly64Controller = nil
    }

    fileprivate static func hvscDidClose() {
        hvscController = nil
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Stream64ToolWindows.assembly64DidClose()
    }
}

@MainActor
final class HVSCWindowController: NSWindowController, NSWindowDelegate {
    init(
        deviceStore: DeviceStore,
        settings: AppSettings,
        library: HVSCLibraryStore,
        sessionProvider: @escaping (UltimateDevice) -> DeviceSession
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "HVSC SID Browser"
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
            })
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Stream64ToolWindows.hvscDidClose()
    }
}

@MainActor
final class FileManagerWindowController: NSWindowController, NSWindowDelegate {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Stream64ToolWindows.fileManagerDidClose()
    }
}
