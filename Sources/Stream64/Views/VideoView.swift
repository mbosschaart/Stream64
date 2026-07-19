import SwiftUI
import MetalKit

/// SwiftUI wrapper around the Metal-backed video view, with C64 keyboard capture.
struct VideoView: NSViewRepresentable {
    @ObservedObject var session: DeviceSession
    /// Observed directly: updateNSView pushes these values to the renderer,
    /// so the view must re-render when they change — regardless of whether
    /// the host view (pane, grid tile) observes them.
    @ObservedObject var display: DisplaySettings
    @EnvironmentObject var settings: AppSettings

    init(session: DeviceSession) {
        self.session = session
        self.display = session.display
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> KeyCapturingMTKView {
        let view = KeyCapturingMTKView(frame: .zero)
        let renderer = MetalFrameRenderer(mtkView: view)
        context.coordinator.renderer = renderer
        view.onKeyText = { text in
            guard settings.captureKeyboardWhenFocused else { return }
            let session = context.coordinator.session
            Task { @MainActor in session.sendKeys(text) }
        }
        context.coordinator.session.videoReceiver.onFrame = { [weak renderer] frame in
            renderer?.submitFrame(frame)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCapturingMTKView, context: Context) {
        context.coordinator.renderer?.scalingMode = display.scalingMode
        context.coordinator.renderer?.filterMode = display.filterMode
        context.coordinator.renderer?.reflectionEnabled = display.bezelReflection
        context.coordinator.renderer?.signalLevel = display.tubeInput.signalLevel
        context.coordinator.renderer?.picture = display.picture
        context.coordinator.renderer?.setPalette(C64Palette.palette(for: display.palette))
    }

    final class Coordinator {
        let session: DeviceSession
        var renderer: MetalFrameRenderer?

        init(session: DeviceSession) {
            self.session = session
        }
    }
}

/// MTKView subclass that becomes first responder and forwards keystrokes
/// to the C64 as keyboard input. Also keeps rendering while the window is
/// occluded (MTKView's display link pauses then, which made background
/// playback jumpy) by driving draw() from a timer.
final class KeyCapturingMTKView: MTKView {
    var onKeyText: ((String) -> Void)?

    private var occlusionObserver: NSObjectProtocol?
    private var backgroundTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        stopBackgroundDriving()
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            if window.occlusionState.contains(.visible) {
                self.stopBackgroundDriving()
            } else {
                self.startBackgroundDriving()
            }
        }
    }

    /// While occluded, MTKView's display link stops; drive draws manually
    /// at the stream rate so frames keep presenting.
    private func startBackgroundDriving() {
        guard backgroundTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 50.0, repeats: true) { [weak self] _ in
            self?.draw()
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    private func stopBackgroundDriving() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    deinit {
        backgroundTimer?.invalidate()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let text = Self.c64Text(for: event) else {
            super.keyDown(with: event)
            return
        }
        onKeyText?(text)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    /// Map a macOS key event to the character sequence expected by the
    /// Ultimate keyboard API (PETSCII-ish plain text; RETURN = \r).
    private static func c64Text(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "\r"          // Return
        case 51: return "\u{14}"      // Delete -> PETSCII DEL
        case 53: return "\u{03}"      // Escape -> RUN/STOP
        case 123: return "\u{9D}"     // Left cursor
        case 124: return "\u{1D}"     // Right cursor
        case 125: return "\u{11}"     // Down cursor
        case 126: return "\u{91}"     // Up cursor
        case 115: return "\u{13}"     // Home
        case 122: return "\u{85}"     // F1
        case 120: return "\u{89}"     // F2
        case 99: return "\u{86}"      // F3
        case 118: return "\u{8A}"     // F4
        case 96: return "\u{87}"      // F5
        case 97: return "\u{8B}"      // F6
        case 98: return "\u{88}"      // F7
        case 100: return "\u{8C}"     // F8
        default:
            guard let chars = event.characters, !chars.isEmpty else { return nil }
            // Filter out function/modifier-only presses.
            if event.modifierFlags.contains(.command) { return nil }
            return chars
        }
    }
}
