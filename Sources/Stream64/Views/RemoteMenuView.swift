import SwiftUI
import AppKit

@MainActor
final class RemoteMenuViewModel: ObservableObject {
    @Published var screen: UltimateMenuScreen
    @Published var status = "Live"

    let session: DeviceSession
    var onUnavailable: (() -> Void)?
    private var pollTask: Task<Void, Never>?

    init(session: DeviceSession, screen: UltimateMenuScreen) {
        self.session = session
        self.screen = screen
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    self.screen = try await self.session.fetchRemoteMenuScreen()
                    self.status = "Live"
                    misses = 0
                } catch {
                    misses += 1
                    self.status = "Waiting for menu…"
                    if misses >= 5 {
                        self.onUnavailable?()
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

}

struct RemoteMenuView: View {
    @ObservedObject var model: RemoteMenuViewModel
    let close: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = min(
                geometry.size.width,
                geometry.size.height * (40.0 / 25.0))
            let height = width * (25.0 / 40.0)
            MenuScreenCanvas(screen: model.screen)
                .frame(width: width, height: height)
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height / 2)
                .overlay {
                    RemoteMenuKeyCapture(
                        session: model.session,
                        close: close)
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
                Text("Arrow keys navigate · Return selects · Esc closes")
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

struct MenuScreenCanvas: View {
    let screen: UltimateMenuScreen

    var body: some View {
        Canvas { context, size in
            let cellWidth = size.width
                / CGFloat(UltimateMenuScreen.columns)
            let cellHeight = size.height
                / CGFloat(UltimateMenuScreen.rows)
            for row in 0..<UltimateMenuScreen.rows {
                for column in 0..<UltimateMenuScreen.columns {
                    let attribute = screen.color(
                        at: column, row: row)
                    var foreground = Self.palette[
                        Int(attribute & 0x0F)]
                    var background = Self.palette[
                        Int((attribute >> 4) & 0x0F)]
                    if screen.character(at: column, row: row) & 0x80 != 0 {
                        swap(&foreground, &background)
                    }
                    let rect = CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth + 0.5,
                        height: cellHeight + 0.5)
                    context.fill(
                        Path(rect), with: .color(background))
                    let character = UltimateMenuGlyph.character(
                        screen.character(at: column, row: row))
                    let text = Text(character)
                        .font(.system(
                            size: cellHeight * 0.82,
                            weight: .medium,
                            design: .monospaced))
                        .foregroundColor(foreground)
                    context.draw(
                        text,
                        at: CGPoint(
                            x: rect.midX, y: rect.midY),
                        anchor: .center)
                }
            }
        }
        .background(Color.black)
    }

}

enum UltimateMenuGlyph {
    nonisolated static func character(_ screenCode: UInt8) -> String {
        let code = screenCode & 0x7F
        if 0x20...0x7E ~= code {
            return String(UnicodeScalar(code))
        }
        switch code {
        case 0x00: return " "
        case 0x01: return "┌"
        case 0x02: return "─"
        case 0x03: return "┐"
        case 0x04: return "│"
        case 0x05: return "└"
        case 0x06: return "┘"
        case 0x07: return "╭"
        case 0x08: return "┬"
        case 0x09: return "╮"
        case 0x0A: return "├"
        case 0x0B: return "▇"
        case 0x0C: return "┤"
        case 0x0D: return "┴"
        case 0x0E: return "╰"
        case 0x0F: return "╯"
        case 0x10: return "α"
        case 0x11: return "β"
        case 0x12: return "▀"
        case 0x13: return "◆"
        default: return "?"
        }
    }

}

private extension MenuScreenCanvas {
    static let palette: [Color] = [
        .black, .white,
        Color(red: 0.53, green: 0.15, blue: 0.20),
        Color(red: 0.42, green: 0.80, blue: 0.76),
        Color(red: 0.50, green: 0.23, blue: 0.55),
        Color(red: 0.35, green: 0.68, blue: 0.32),
        Color(red: 0.20, green: 0.20, blue: 0.60),
        Color(red: 0.82, green: 0.82, blue: 0.35),
        Color(red: 0.55, green: 0.35, blue: 0.20),
        Color(red: 0.35, green: 0.25, blue: 0.12),
        Color(red: 0.78, green: 0.35, blue: 0.40),
        Color(white: 0.33),
        Color(white: 0.50),
        Color(red: 0.60, green: 0.90, blue: 0.55),
        Color(red: 0.45, green: 0.45, blue: 0.80),
        Color(white: 0.70),
    ]
}

private struct RemoteMenuKeyCapture: NSViewRepresentable {
    let session: DeviceSession
    let close: () -> Void

    func makeNSView(context: Context) -> RemoteMenuCaptureNSView {
        let view = RemoteMenuCaptureNSView()
        view.session = session
        view.closeAction = close
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(
        _ nsView: RemoteMenuCaptureNSView,
        context: Context
    ) {
        nsView.session = session
        nsView.closeAction = close
    }
}

private final class RemoteMenuCaptureNSView: NSView {
    weak var session: DeviceSession?
    var closeAction: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            closeAction?()
            return
        }
        guard let session else { return }
        let input = HostKeyInput(
            keyCode: event.keyCode,
            characters: event.characters,
            modifiers: event.modifierFlags.intersection(
                .deviceIndependentFlagsMask),
            isRepeat: event.isARepeat)
        if !session.handleHostKeyDown(input) {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let session else { return }
        let input = HostKeyInput(
            keyCode: event.keyCode,
            characters: event.characters,
            modifiers: event.modifierFlags.intersection(
                .deviceIndependentFlagsMask),
            isRepeat: event.isARepeat)
        if !session.handleHostKeyUp(input) {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard session?.handleModifierChange(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags.intersection(
                .deviceIndependentFlagsMask)) == true else {
            super.flagsChanged(with: event)
            return
        }
    }

    override func resignFirstResponder() -> Bool {
        session?.input.releaseAll()
        return super.resignFirstResponder()
    }
}

@MainActor
final class RemoteMenuWindowController:
    NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: RemoteMenuWindowController] = [:]

    private let deviceID: UUID
    private let model: RemoteMenuViewModel
    private var closeDeviceMenu = true

    static func show(
        session: DeviceSession,
        screen: UltimateMenuScreen
    ) {
        if let existing = windows[session.device.id] {
            existing.model.screen = screen
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = RemoteMenuWindowController(
            session: session, screen: screen)
        windows[session.device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.model.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(
        session: DeviceSession,
        screen: UltimateMenuScreen
    ) {
        deviceID = session.device.id
        model = RemoteMenuViewModel(
            session: session, screen: screen)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: 800, height: 540),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
            ],
            backing: .buffered, defer: false)
        window.title = "\(session.device.name) Menu"
        window.minSize = NSSize(width: 560, height: 390)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        model.onUnavailable = { [weak self] in
            self?.closeDeviceMenu = false
            self?.close()
        }
        window.contentViewController = NSHostingController(
            rootView: RemoteMenuView(
                model: model,
                close: { [weak self] in self?.close() }))
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        model.session.input.releaseAll()
        Self.windows.removeValue(forKey: deviceID)
        if closeDeviceMenu {
            Task { await model.session.closeRemoteMenuFromWindow() }
        }
    }
}
