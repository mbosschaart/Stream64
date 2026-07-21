import SwiftUI

enum Stream64Version {
    static let display = "0.91b"
}

/// Quits the app when the main viewer window closes — otherwise an open
/// Settings window keeps the process alive, looking like the app refused
/// to exit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = SingleInstanceLock()
    private var isTerminatingCompletely = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard case .alreadyRunning(let pid) = instanceLock.acquire() else {
            return
        }

        // Repeated `swift run` launches otherwise create multiple UDP
        // listeners with endpoint reuse enabled. Packets may be delivered to
        // the older process while the new window reports "No video arriving."
        if let pid, let existing = NSRunningApplication(processIdentifier: pid) {
            existing.activate(options: [.activateAllWindows])
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Also cover Command-Q / Dock Quit, not only red-close on the viewer.
        if !isTerminatingCompletely {
            isTerminatingCompletely = true
            for window in sender.windows {
                window.orderOut(nil)
                window.close()
            }
        }
        return .terminateNow
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
    /// Persistent library state survives Assembly64 window reconstruction.
    @StateObject private var assembly64Library = Assembly64LibraryStore()

    init() {
        // Needed when launched via `swift run` (no app bundle): become a regular
        // foreground app with a menu bar and dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Stream64") {
            ContentView()
                .environmentObject(deviceStore)
                .environmentObject(settings)
                .environmentObject(sessionManager)
                .frame(minWidth: 900, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Stream64") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Stream64",
                        .applicationVersion: Stream64Version.display,
                        .credits: NSAttributedString(
                            string: "Designed by Martijn Bosschaart 2026",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]),
                    ])
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

        Settings {
            SettingsView()
                .environmentObject(deviceStore)
                .environmentObject(settings)
        }
    }
}

extension Notification.Name {
    static let addDeviceRequested = Notification.Name("addDeviceRequested")
    static let saveScreenshotRequested = Notification.Name("saveScreenshotRequested")
}
