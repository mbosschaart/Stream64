import SwiftUI

enum Stream64Version {
    /// Release packaging writes CFBundleShortVersionString into the app
    /// bundle. Reading it here prevents VERSION= overrides from disagreeing
    /// with About/splash/help; swift run has no bundle metadata, so retain a
    /// development fallback.
    static var display: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.124b"
    }
}

/// A packaged .app has its resources flattened into `Contents/Resources`
/// (see `Scripts/build-release.sh`), so `Bundle.main` always finds them
/// there. `swift run` never gets that flattening step and relies on
/// SwiftPM's generated `Bundle.module` instead — but merely *referencing*
/// `Bundle.module` traps with a fatal error when its resource bundle isn't
/// present, so it must never be touched from a packaged app.
enum ResourceBundle {
    static let isPackagedApp = Bundle.main.bundleURL.pathExtension == "app"
}

enum Stream64Assets {
    static let aboutLogo = image(named: "logofactuur")
    static let applicationIcon = image(named: "Stream64logo")

    private static func image(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        guard !ResourceBundle.isPackagedApp,
              let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }
}

/// Quits the app when the main viewer window closes — otherwise an open
/// Settings window keeps the process alive, looking like the app refused
/// to exit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = SingleInstanceLock()
    private var isTerminatingCompletely = false
    private var didReplyToTerminate = false
    /// Strong on purpose: quit must still reach sessions after SwiftUI has
    /// torn down the main window / `onAppear` wiring.
    var sessionManager: SessionManager?
    private var splashWindow: NSWindow?
    private var hiddenLaunchWindows: [NSWindow] = []
    private var windowOrderObserver: NSObjectProtocol?
    private var windowFullScreenPolicyObserver: NSObjectProtocol?
    private var isShowingSplash = false
    /// Cap remote stream-stop work during quit so an unreachable device
    /// cannot leave Stream64 as a zombie process with audio still playing.
    private static let terminationCleanupLimit: Duration = .seconds(2)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window is created: own-Space full screen for every
        // titled window (viewer, Assembly64, File Manager, SID, tools, …).
        NSWindow.allowsAutomaticWindowTabbing = false
        Stream64WindowPolicy.install()
        switch instanceLock.acquire() {
        case .acquired:
            prepareForSplash()
        case .alreadyRunning(let pid):
            // Repeated `swift run` launches otherwise create multiple UDP
            // listeners with endpoint reuse enabled. Packets may be delivered
            // to the older process while the new window reports no video.
            if let pid, let existing = NSRunningApplication(
                processIdentifier: pid
            ) {
                existing.activate(options: [.activateAllWindows])
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installIndependentFullScreenPolicyObserver()
        guard isShowingSplash else { return }
        showSplashWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finishSplash()
        }
    }

    /// Secondary windows must be `fullScreenPrimary` so Assembly64 / Help /
    /// File Manager / SID panels can each maximize onto their own Space while
    /// the viewer stays full screen elsewhere.
    private func installIndependentFullScreenPolicyObserver() {
        guard windowFullScreenPolicyObserver == nil else { return }
        let apply: @Sendable (Notification) -> Void = { note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
            }
        }
        windowFullScreenPolicyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main,
            using: apply)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main,
            using: apply)
        // Re-assert before AppKit commits the Space transition.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: nil,
            queue: .main,
            using: apply)
        for window in NSApp.windows {
            Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep false during the splash handoff — the viewer window already
        // exists (hidden) and returning true would quit mid-launch. After
        // splash, closing the last window must quit even if the main-viewer
        // willClose observer lost the race with SwiftUI teardown.
        !isShowingSplash
    }

    /// Called by the updater immediately before `exit` so local audio/AirPlay
    /// stop without going through the AppKit terminate path (which can stall
    /// on the update sheet).
    func prepareForUpdateRelaunch() {
        sessionManager?.prepareForAppTermination()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Also cover Command-Q / Dock Quit, not only red-close on the viewer.
        // Remote streams use duration 0 by default; we still try to stop them,
        // but local audio/AirPlay must die immediately and quit must never
        // hang forever waiting on REST.
        if isTerminatingCompletely {
            return didReplyToTerminate ? .terminateNow : .terminateLater
        }
        isTerminatingCompletely = true

        // Stop music and free UDP ports before any await / window teardown.
        sessionManager?.prepareForAppTermination()

        for window in sender.windows {
            window.orderOut(nil)
            window.close()
        }

        Task { @MainActor [weak self] in
            guard let self else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            await self.runTerminationCleanup()
            self.finishTermination()
        }
        // Safety net if remote stop stalls past the cleanup limit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.finishTermination()
        }
        return .terminateLater
    }

    private func runTerminationCleanup() async {
        guard let sessionManager else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await sessionManager.disconnectAll()
            }
            group.addTask {
                try? await Task.sleep(for: Self.terminationCleanupLimit)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func finishTermination() {
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        // Belt-and-suspenders: local teardown again in case sessions were
        // created after the first prepare call.
        sessionManager?.prepareForAppTermination()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func prepareForSplash() {
        isShowingSplash = true
        windowOrderObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isShowingSplash else { return }
                for window in NSApp.windows
                where window !== self.splashWindow && window.isVisible {
                    if !self.hiddenLaunchWindows.contains(
                        where: { $0 === window }
                    ) {
                        self.hiddenLaunchWindows.append(window)
                    }
                    window.alphaValue = 0
                    window.ignoresMouseEvents = true
                }
            }
        }
    }

    private func showSplashWindow() {
        let size = NSSize(width: 440, height: 440)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(
            rootView: SplashView()
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let targetScreen = hiddenLaunchWindows.first?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen = targetScreen {
            let screenFrame = screen.frame
            window.setFrameOrigin(NSPoint(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.midY - size.height / 2
            ))
        } else {
            window.center()
        }
        splashWindow = window
        window.orderFrontRegardless()
    }

    private func finishSplash() {
        guard isShowingSplash else { return }

        var launchWindows = hiddenLaunchWindows
        for window in NSApp.windows
        where window !== splashWindow && window.canBecomeMain {
            if !launchWindows.contains(where: { $0 === window }) {
                launchWindows.append(window)
            }
        }
        guard !launchWindows.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                [weak self] in
                self?.finishSplash()
            }
            return
        }

        isShowingSplash = false
        if let windowOrderObserver {
            NotificationCenter.default.removeObserver(windowOrderObserver)
            self.windowOrderObserver = nil
        }

        for window in launchWindows {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            window.orderFront(nil)
        }
        launchWindows.first?.makeKeyAndOrderFront(nil)
        hiddenLaunchWindows.removeAll()

        splashWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct Stream64App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var deviceStore = DeviceStore()
    @StateObject private var settings = AppSettings()
    /// App-level so the main window and the Assembly64 browser share the
    /// same live sessions.
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var updateService = UpdateService()
    /// Persistent library state survives Assembly64 window reconstruction.
    @StateObject private var assembly64Library = Assembly64LibraryStore()
    /// Optional local Songlengths.md5 cache survives HVSC window recreation.
    @StateObject private var hvscLibrary = HVSCLibraryStore()

    init() {
        // Needed when launched via `swift run` (no app bundle): become a regular
        // foreground app with a menu bar and dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
        if let icon = Stream64Assets.applicationIcon {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // Keep AppKit tool-window presenters wired even before the viewer
        // finishes appearing (menu bar Assembly64 / File Manager).
        let _ = {
            appDelegate.sessionManager = sessionManager
            Stream64ToolWindows.configure(
                deviceStore: deviceStore,
                settings: settings,
                sessionManager: sessionManager,
                assembly64Library: assembly64Library,
                hvscLibrary: hvscLibrary)
        }()
        WindowGroup("Stream64") {
            ContentView()
                .environmentObject(deviceStore)
                .environmentObject(settings)
                .environmentObject(sessionManager)
                .environmentObject(updateService)
                .independentFullScreenWindow()
                .onAppear {
                    appDelegate.sessionManager = sessionManager
                    Stream64ToolWindows.configure(
                        deviceStore: deviceStore,
                        settings: settings,
                        sessionManager: sessionManager,
                        assembly64Library: assembly64Library,
                        hvscLibrary: hvscLibrary)
                }
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    updateService.checkAutomatically()
                }
                .sheet(isPresented: $updateService.isPresented) {
                    UpdateSheet()
                        .environmentObject(updateService)
                }
                .frame(minWidth: 900, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Stream64") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateService.check(force: true)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Add Device…") {
                    NotificationCenter.default.post(name: .addDeviceRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Search Assembly64…") {
                    Stream64ToolWindows.showAssembly64()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Search HVSC…") {
                    Stream64ToolWindows.showHVSC()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("File Manager…") {
                    Stream64ToolWindows.showFileManager()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Save Screenshot…") {
                    NotificationCenter.default.post(name: .saveScreenshotRequested, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            // Full per-stream control set (mirrors the video right-click menu).
            // Uses DeviceStore selection — not focusedSceneObject — so the
            // menu still works when the full-screen viewer is on another Space.
            StreamSessionCommands(
                deviceStore: deviceStore,
                settings: settings,
                sessionManager: sessionManager)
            CommandGroup(replacing: .help) {
                Button("Stream64 Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Stream64 Help", id: "help") {
            HelpView()
                .independentFullScreenWindow()
        }
        .defaultSize(width: 860, height: 600)

        Window("About Stream64", id: "about") {
            AboutView()
                .independentFullScreenWindow()
        }
        .defaultSize(width: 520, height: 320)
        .windowResizability(.contentSize)

        // Assembly64 + File Manager use AppKit NSWindowControllers (see
        // Stream64ToolWindows) so full screen gets its own Space like
        // Ultimate Config — SwiftUI Window scenes bypass the NSWindow swizzle.

        Settings {
            SettingsView()
                .environmentObject(deviceStore)
                .environmentObject(settings)
                .environmentObject(sessionManager)
                .environmentObject(updateService)
                .independentFullScreenWindow()
        }
    }
}

extension Notification.Name {
    static let addDeviceRequested = Notification.Name("addDeviceRequested")
    static let saveScreenshotRequested = Notification.Name("saveScreenshotRequested")
    /// Posted by the Stream menu bar / shared menu; `object` is the
    /// `DeviceSession` to power off (host shows confirmation when needed).
    static let powerOffRequested = Notification.Name("powerOffRequested")
}
