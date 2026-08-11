import SwiftUI

enum Stream64Version {
    /// Release packaging writes CFBundleShortVersionString into the app
    /// bundle. Reading it here prevents VERSION= overrides from disagreeing
    /// with About/splash/help; swift run has no bundle metadata, so retain a
    /// development fallback.
    static var display: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.114b"
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
    private var isShowingSplash = false
    /// Cap remote stream-stop work during quit so an unreachable device
    /// cannot leave Stream64 as a zombie process with audio still playing.
    private static let terminationCleanupLimit: Duration = .seconds(2)

    func applicationWillFinishLaunching(_ notification: Notification) {
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
        guard isShowingSplash else { return }
        showSplashWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finishSplash()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep false during the splash handoff — the viewer window already
        // exists (hidden) and returning true would quit mid-launch. After
        // splash, closing the last window must quit even if the main-viewer
        // willClose observer lost the race with SwiftUI teardown.
        !isShowingSplash
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

        // Post-update relaunch: exit immediately so the waiter script can
        // open the new binary. A `.terminateLater` disconnect wait (or
        // Launch Services activating this still-running instance) was what
        // left the install sheet beachballing.
        if UpdateService.isRelaunchingAfterUpdate {
            for window in sender.windows {
                window.orderOut(nil)
            }
            return .terminateNow
        }

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
        WindowGroup("Stream64") {
            ContentView()
                .environmentObject(deviceStore)
                .environmentObject(settings)
                .environmentObject(sessionManager)
                .environmentObject(updateService)
                .onAppear {
                    appDelegate.sessionManager = sessionManager
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
                    openWindow(id: "assembly64")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("File Manager…") {
                    openWindow(id: "files")
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Save Screenshot…") {
                    NotificationCenter.default.post(name: .saveScreenshotRequested, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Stream64 Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Stream64 Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 860, height: 600)

        Window("About Stream64", id: "about") {
            AboutView()
        }
        .defaultSize(width: 520, height: 320)
        .windowResizability(.contentSize)

        Window("Assembly64", id: "assembly64") {
            Assembly64View { device in
                sessionManager.session(for: device, settings: settings)
            }
            .environmentObject(deviceStore)
            .environmentObject(settings)
            .environmentObject(assembly64Library)
        }
        .defaultSize(width: 980, height: 680)
        // Default resizability ties the window's size to its content's
        // *ideal* size — so the moment the files pane grows wider (an
        // entry row with filename/size/action buttons has a wider ideal
        // width than the "No Item Selected" placeholder it replaces), the
        // window snaps outward to match, and never shrinks back. Pinning
        // to just a minimum keeps the window at whatever size it already
        // is (or whatever the user set) as long as that's big enough —
        // it only grows if genuinely necessary, never because a subview's
        // ideal size changed. Paired with a wide-enough defaultSize above
        // and minWidth in Assembly64View, the window now opens already at
        // the size it used to only reach after your first selection.
        .windowResizability(.contentMinSize)

        Window("File Manager", id: "files") {
            RemoteBrowserView()
                .environmentObject(deviceStore)
                .environmentObject(settings)
                .environmentObject(sessionManager)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(deviceStore)
                .environmentObject(settings)
                .environmentObject(sessionManager)
                .environmentObject(updateService)
        }
    }
}

extension Notification.Name {
    static let addDeviceRequested = Notification.Name("addDeviceRequested")
    static let saveScreenshotRequested = Notification.Name("saveScreenshotRequested")
}
