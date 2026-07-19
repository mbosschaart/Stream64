import SwiftUI

/// Quits the app when the main viewer window closes — otherwise an open
/// Settings window keeps the process alive, looking like the app refused
/// to exit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, Self.isMainWindow(window) else { return }
            // Closing the viewer means quitting: take Settings (and any
            // other panel) down with it.
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    /// The viewer window, as opposed to Settings (identified by SwiftUI's
    /// settings-window identifier) or utility panels/sheets. The main
    /// window's title varies (it shows the device name), so identify by
    /// exclusion.
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue.contains("Settings") == true { return false }
        if window.identifier?.rawValue.contains("help") == true { return false }
        if window.identifier?.rawValue.contains("assembly64") == true { return false }
        if window is NSPanel || window.isSheet { return false }
        return window.canBecomeMain
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
                        .applicationVersion: "1.0",
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
        }
        .defaultSize(width: 760, height: 640)

        Settings {
            SettingsView()
                .environmentObject(deviceStore)
                .environmentObject(settings)
        }
    }
}

extension Notification.Name {
    static let addDeviceRequested = Notification.Name("addDeviceRequested")
}
