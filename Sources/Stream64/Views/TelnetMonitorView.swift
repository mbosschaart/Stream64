import SwiftUI
import AppKit

/// Drives a Telnet session to the Ultimate (port 23, VT100) so the on-device
/// menu system and Machine Code Monitor — native firmware UI with no REST
/// equivalent — can be viewed and driven remotely, without interrupting
/// whatever's running on the C64 (unlike the REST-based `RemoteMenuView`,
/// which pauses the machine while its menu is open). In everyday use this
/// is mostly a live, non-interrupting view of the on-screen menu — hence
/// the user-facing name "Ultimate Menu" rather than "Machine Monitor,"
/// even though the same window can also reach the real Machine Code
/// Monitor if navigated there. See `UltimateTelnetClient` and
/// `VT100Screen` for the transport/decode halves.
@MainActor
final class TelnetMonitorViewModel: ObservableObject {
    let screen: VT100Screen
    /// Bumped on every received chunk so the `Canvas` (which reads directly
    /// from the class-backed `screen`, not through `@Published` storage)
    /// knows to redraw.
    @Published private(set) var revision = 0
    @Published private(set) var status = "Connecting…"

    let session: DeviceSession
    private let client = UltimateTelnetClient()

    init(session: DeviceSession, columns: Int = 80, rows: Int = 25) {
        self.session = session
        self.screen = VT100Screen(columns: columns, rows: rows)
    }

    func start() {
        client.onData = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screen.feed(data)
                self.revision += 1
            }
        }
        client.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .connecting: self.status = "Connecting…"
                case .ready: self.status = "Live"
                case .failed(let message): self.status = "Disconnected: \(message)"
                case .cancelled: self.status = "Disconnected"
                }
            }
        }
        screen.reset()
        client.connect(host: session.device.host)
    }

    func stop() {
        client.disconnect()
    }

    func send(_ data: Data) {
        client.send(data)
    }
}

struct TelnetMonitorView: View {
    @ObservedObject var model: TelnetMonitorViewModel
    let close: () -> Void

    var body: some View {
        GeometryReader { geometry in
            // Terminal characters are roughly twice as tall as they are
            // wide; scale the grid to fit while preserving that shape.
            let aspect = CGFloat(model.screen.columns)
                / CGFloat(model.screen.rows) / 2.0
            let width = min(geometry.size.width, geometry.size.height * aspect)
            let height = width / aspect
            TerminalCanvas(model: model)
                .frame(width: width, height: height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .overlay {
                    TelnetKeyCapture(model: model)
                        .allowsHitTesting(false)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text(model.status)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Arrow/function keys navigate · C=+letter is best-effort")
                        .foregroundStyle(.secondary)
                    Button("Close", action: close)
                }
                .font(.caption)
                .padding(8)
            }
            .background(.bar)
        }
        .background(Color.black)
    }
}

private struct TerminalCanvas: View {
    @ObservedObject var model: TelnetMonitorViewModel

    var body: some View {
        Canvas { context, size in
            _ = model.revision // dependency: redraw whenever new bytes arrive
            let screen = model.screen
            let cellWidth = size.width / CGFloat(screen.columns)
            let cellHeight = size.height / CGFloat(screen.rows)
            for row in 0..<screen.rows {
                for column in 0..<screen.columns {
                    let cell = screen.cell(atColumn: column, row: row)
                    var foreground = Self.palette[Int(cell.foreground) % 8]
                    var background = Self.palette[Int(cell.background) % 8]
                    if cell.reversed { swap(&foreground, &background) }
                    let rect = CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth + 0.5,
                        height: cellHeight + 0.5)
                    context.fill(Path(rect), with: .color(background))
                    let text = Text(String(cell.character))
                        .font(.system(
                            size: cellHeight * 0.82,
                            weight: cell.bold ? .bold : .regular,
                            design: .monospaced))
                        .foregroundColor(foreground)
                    context.draw(
                        text,
                        at: CGPoint(x: rect.midX, y: rect.midY),
                        anchor: .center)
                }
            }
            let cursorRect = CGRect(
                x: CGFloat(screen.cursorColumn) * cellWidth,
                y: CGFloat(screen.cursorRow) * cellHeight,
                width: cellWidth, height: cellHeight)
            context.fill(Path(cursorRect), with: .color(.white.opacity(0.25)))
        }
        .background(Color.black)
    }

    private static let palette: [Color] = [
        .black, .red, .green, .yellow, .blue, .purple, .cyan, .white,
    ]
}

private struct TelnetKeyCapture: NSViewRepresentable {
    let model: TelnetMonitorViewModel

    func makeNSView(context: Context) -> TelnetKeyCaptureNSView {
        let view = TelnetKeyCaptureNSView()
        view.model = model
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TelnetKeyCaptureNSView, context: Context) {
        nsView.model = model
    }
}

private final class TelnetKeyCaptureNSView: NSView {
    weak var model: TelnetMonitorViewModel?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let model, let bytes = Self.encode(event) else {
            super.keyDown(with: event)
            return
        }
        model.send(bytes)
    }

    /// Best-effort VT100/xterm encoding for a keystroke. Arrow keys and the
    /// first eight function keys use their standard xterm escape
    /// sequences, which any VT100-compatible session — including
    /// Ultimate's Telnet server — should understand.
    ///
    /// `Command+letter` is sent using the conventional "Meta sends escape"
    /// terminal prefix, as a stand-in for the physical `C=` (Commodore)
    /// modifier Ultimate's own keyboard shortcuts use (`C=+O` opens the
    /// monitor, `C=+I` swaps overlay/freeze, etc.). **This mapping is
    /// unverified** — Ultimate's own contributors have noted
    /// modifier-heavy shortcuts can be "problematic" over Telnet; if it
    /// doesn't reach the monitor, navigate the on-device menu with the
    /// arrow/function keys instead (see HANDOVER.md).
    static func encode(_ event: NSEvent) -> Data? {
        if event.modifierFlags.contains(.command),
           let characters = event.charactersIgnoringModifiers,
           !characters.isEmpty {
            return Data([0x1B] + Array(characters.utf8))
        }
        switch event.keyCode {
        case 123: return Data([0x1B, UInt8(ascii: "["), UInt8(ascii: "D")]) // Left
        case 124: return Data([0x1B, UInt8(ascii: "["), UInt8(ascii: "C")]) // Right
        case 125: return Data([0x1B, UInt8(ascii: "["), UInt8(ascii: "B")]) // Down
        case 126: return Data([0x1B, UInt8(ascii: "["), UInt8(ascii: "A")]) // Up
        case 36: return Data([0x0D])  // Return
        case 51: return Data([0x7F])  // Backspace/Delete
        case 53: return Data([0x1B])  // Escape
        case 48: return Data([0x09])  // Tab
        case 122: return Data("\u{1B}OP".utf8) // F1
        case 120: return Data("\u{1B}OQ".utf8) // F2
        case 99: return Data("\u{1B}OR".utf8)  // F3
        case 118: return Data("\u{1B}OS".utf8) // F4
        case 96: return Data("\u{1B}[15~".utf8) // F5
        case 97: return Data("\u{1B}[17~".utf8) // F6
        case 98: return Data("\u{1B}[18~".utf8) // F7
        case 100: return Data("\u{1B}[19~".utf8) // F8
        default:
            guard let characters = event.characters, !characters.isEmpty else { return nil }
            return Data(characters.utf8)
        }
    }
}

@MainActor
final class TelnetMonitorWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: TelnetMonitorWindowController] = [:]

    private let deviceID: UUID
    private let model: TelnetMonitorViewModel

    static func show(session: DeviceSession) {
        if let existing = windows[session.device.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = TelnetMonitorWindowController(session: session)
        windows[session.device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.model.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(session: DeviceSession) {
        deviceID = session.device.id
        model = TelnetMonitorViewModel(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
            ],
            backing: .buffered, defer: false)
        window.title = "\(session.device.name) Ultimate Menu"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: TelnetMonitorView(
                model: model,
                close: { [weak self] in self?.close() }))
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.windows.removeValue(forKey: deviceID)
    }
}
