import SwiftUI
import AppKit

/// Developer peek/poke console over `readmem` / `writemem`.
struct MemoryConsoleView: View {
    @ObservedObject var model: MemoryConsoleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Memory Console")
                    .font(.headline)
                Spacer()
                if let status = model.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                Text("Address")
                TextField("$C000", text: $model.addressText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 90)
                Text("Length")
                TextField("256", text: $model.lengthText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 60)
                Button("Read") {
                    Task { await model.readMemory() }
                }
                .fixedSize()
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || !model.session.isConnected)
            }

            ScrollView {
                Text(model.hexDump.isEmpty ? " " : model.hexDump)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            GroupBox("Poke") {
                HStack {
                    Text("Bytes (hex)")
                    TextField("00 FF A9", text: $model.pokeBytesText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Button("Write") {
                        Task { await model.writeMemory() }
                    }
                    .fixedSize()
                    .disabled(model.busy || !model.session.isConnected)
                }
                Text("Writes at the address above. Separate bytes with spaces or commas.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 380)
    }
}

@MainActor
final class MemoryConsoleViewModel: ObservableObject {
    let session: DeviceSession
    @Published var addressText = "C000"
    @Published var lengthText = "256"
    @Published var pokeBytesText = ""
    @Published private(set) var hexDump = ""
    @Published private(set) var statusMessage: String?
    @Published private(set) var busy = false

    init(session: DeviceSession) {
        self.session = session
    }

    func readMemory() async {
        guard session.isConnected else {
            statusMessage = "Not connected."
            return
        }
        guard let address = Self.parseAddress(addressText) else {
            statusMessage = "Invalid address (use hex, e.g. C000 or $D020)."
            return
        }
        guard let length = Int(lengthText.trimmingCharacters(in: .whitespaces)),
              (1...256).contains(length) else {
            statusMessage = "Length must be 1…256."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let data = try await session.api.readMemory(
                address: address, length: length)
            hexDump = Self.formatHexDump(data, start: address)
            statusMessage = "Read \(data.count) byte(s) from $\(String(format: "%04X", address))."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func writeMemory() async {
        guard session.isConnected else {
            statusMessage = "Not connected."
            return
        }
        guard let address = Self.parseAddress(addressText) else {
            statusMessage = "Invalid address."
            return
        }
        guard let bytes = Self.parseHexBytes(pokeBytesText), !bytes.isEmpty else {
            statusMessage = "Enter one or more hex bytes to poke."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await session.api.writeMemory(address: address, bytes: bytes)
            statusMessage = "Wrote \(bytes.count) byte(s) at $\(String(format: "%04X", address))."
            lengthText = String(bytes.count)
            await readMemory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    static func parseAddress(_ raw: String) -> UInt16? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("$") { hex.removeFirst() }
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        return UInt16(hex, radix: 16)
    }

    static func parseHexBytes(_ raw: String) -> [UInt8]? {
        let cleaned = raw
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        var bytes: [UInt8] = []
        for token in cleaned {
            var hex = String(token)
            if hex.hasPrefix("$") { hex.removeFirst() }
            guard let value = UInt8(hex, radix: 16) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    static func formatHexDump(_ data: Data, start: UInt16) -> String {
        var lines: [String] = []
        var offset = 0
        while offset < data.count {
            let rowAddr = Int(start) + offset
            let end = min(offset + 16, data.count)
            let slice = data[offset..<end]
            let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
            let paddedHex = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = slice.map { byte -> Character in
                (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            }
            lines.append(String(
                format: "%04X  %@  |%@|",
                rowAddr & 0xFFFF,
                paddedHex,
                String(ascii)))
            offset = end
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class MemoryConsoleWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: MemoryConsoleWindowController] = [:]
    private let deviceID: UUID

    static func show(session: DeviceSession) {
        if let existing = windows[session.device.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = MemoryConsoleWindowController(session: session)
        windows[session.device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(session: DeviceSession) {
        deviceID = session.device.id
        let model = MemoryConsoleViewModel(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(session.device.name) Memory Console"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MemoryConsoleView(model: model))
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Self.windows.removeValue(forKey: deviceID)
    }
}
