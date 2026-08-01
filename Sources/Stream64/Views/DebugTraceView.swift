import SwiftUI
import AppKit

/// One row in the live decoded trace table. `DebugStreamEntry` itself has
/// no identity, so rows get one assigned as they're flushed from the
/// receiver — stable enough for `Table` while the row is on screen.
struct DebugTraceRow: Identifiable {
    let id: Int
    let entry: DebugStreamEntry
}

enum DebugTraceDisplayMode: String, CaseIterable, Identifiable {
    case table = "Table"
    case memoryMap = "Memory Map"
    var id: String { rawValue }
}

@MainActor
final class DebugTraceViewModel: ObservableObject {
    /// Rows kept for the live table. The debug stream can carry on the
    /// order of a million words/second, far more than any SwiftUI list
    /// should ever be asked to hold — entries are coalesced on a receive
    /// queue and only the most recent window is published, at a fixed
    /// throttle (see `start()`), rather than growing the array per packet.
    static let maxDisplayedRows = 500

    let session: DeviceSession
    /// 64K-address activity map feeding `MemoryMapView`. Updated directly
    /// from the receiver's callback (see `start()`), independent of the
    /// throttled `rows` table — the heatmap wants every access, the table
    /// only wants a display-sized recent window.
    let heatmap = MemoryHeatmap()
    @Published private(set) var rows: [DebugTraceRow] = []
    @Published private(set) var wordsPerSecond: Double = 0
    @Published private(set) var missedPackets: Int = 0
    @Published var selectedMode: DebugStreamMode = .cpu6510Only
    @Published var displayMode: DebugTraceDisplayMode = .memoryMap
    @Published var isPaused = false
    @Published private(set) var isCapturing = false
    @Published private(set) var exportStatus: String?

    private var pendingEntries: [DebugStreamEntry] = []
    private let pendingLock = NSLock()
    private var flushTimer: Timer?
    private var nextRowID = 0
    private var entriesObserverID: UUID?
    private var statsObserverID: UUID?

    init(session: DeviceSession) {
        self.session = session
    }

    /// Register as one of possibly several observers on the (persistent,
    /// session-owned) receiver — the SID Oscilloscope window can watch the
    /// same trace at the same time — and start the UI refresh timer. Call
    /// once when the window opens.
    func start() {
        entriesObserverID = session.debugStreamReceiver.addEntriesObserver { [weak self] entries in
            guard let self else { return }
            if !self.isPaused {
                self.heatmap.record(entries)
            }
            self.pendingLock.lock()
            self.pendingEntries.append(contentsOf: entries)
            let overflow = self.pendingEntries.count - Self.maxDisplayedRows * 4
            if overflow > 0 {
                self.pendingEntries.removeFirst(overflow)
            }
            self.pendingLock.unlock()
        }
        statsObserverID = session.debugStreamReceiver.addStatsObserver { [weak self] rate in
            guard let self else { return }
            Task { @MainActor in
                self.wordsPerSecond = rate
                self.missedPackets = self.session.debugStreamReceiver.missedPackets
            }
        }
        flushTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flush() }
        }
    }

    /// Detach from the receiver's callbacks. Call when the window closes —
    /// this does not itself stop the trace (see `stopTrace()`), and other
    /// observers (e.g. a SID Oscilloscope window) keep receiving data.
    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        if let entriesObserverID {
            session.debugStreamReceiver.removeEntriesObserver(entriesObserverID)
        }
        if let statsObserverID {
            session.debugStreamReceiver.removeStatsObserver(statsObserverID)
        }
    }

    private func flush() {
        guard !isPaused else { return }
        pendingLock.lock()
        let snapshot = pendingEntries
        pendingLock.unlock()
        guard !snapshot.isEmpty else { return }
        rows = snapshot.suffix(Self.maxDisplayedRows).map { entry in
            nextRowID += 1
            return DebugTraceRow(id: nextRowID, entry: entry)
        }
    }

    private func clearBuffers() {
        pendingLock.lock()
        pendingEntries.removeAll()
        pendingLock.unlock()
        rows = []
        heatmap.reset()
    }

    /// Which bus the memory map should show landmarks for — the mode
    /// actually running if a trace is active, otherwise the picker's
    /// current selection (so the legend still updates while choosing a
    /// mode before pressing Start).
    var activeSource: DebugStreamSource {
        if case .active(let mode) = session.debugTraceState {
            return mode.decodeSource
        }
        return selectedMode.decodeSource
    }

    func startTrace() async {
        clearBuffers()
        await session.startDebugTrace(mode: selectedMode)
    }

    func stopTrace() async {
        await session.stopDebugTrace()
    }

    /// Toggle raw-bytes capture on the receiver. Stopping presents a save
    /// panel for the captured bytes — laid out exactly like the official
    /// `grab_debug.py` output, so it drops straight into the documented
    /// `dump_bus_trace.c`/GtkWave pipeline.
    func toggleCapture() {
        if isCapturing {
            session.debugStreamReceiver.stopCaptureAndExportData { [weak self] data in
                guard let self else { return }
                self.isCapturing = false
                self.presentSavePanel(
                    suggestedName: "\(self.session.device.name) debug trace.bin",
                    contents: .binary(data))
            }
        } else {
            session.debugStreamReceiver.startCapture()
            isCapturing = true
        }
    }

    /// Export the currently-visible decoded rows as CSV — a quick way to
    /// look at a short window of the trace without GtkWave.
    func exportVisibleRowsAsCSV() {
        guard !rows.isEmpty else {
            exportStatus = "No entries to export yet."
            scheduleClearExportStatus()
            return
        }
        var csv = "R_W,Address,Data,PHI2,Flags\n"
        for row in rows {
            let entry = row.entry
            csv += "\(entry.isRead ? "R" : "W"),"
                + "$\(String(format: "%04X", entry.address)),"
                + "$\(String(format: "%02X", entry.data)),"
                + "\(entry.phi2 ? 1 : 0),"
                + "\(Self.flagsDescription(entry))\n"
        }
        presentSavePanel(
            suggestedName: "\(session.device.name) debug trace.csv",
            contents: .text(csv))
    }

    private enum ExportContents {
        case binary(Data)
        case text(String)
    }

    private func presentSavePanel(suggestedName: String, contents: ExportContents) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }
            do {
                switch contents {
                case .binary(let data): try data.write(to: url)
                case .text(let text): try text.write(to: url, atomically: true, encoding: .utf8)
                }
                self.exportStatus = "Saved \(url.lastPathComponent)"
            } catch {
                self.exportStatus = "Save failed: \(error.localizedDescription)"
            }
            self.scheduleClearExportStatus()
        }
    }

    private func scheduleClearExportStatus() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.exportStatus = nil
        }
    }

    /// Human-readable asserted-signal summary for the flags column. All of
    /// these are active-low (`#`) signals on the real bus, so "asserted"
    /// means the stored raw bit is `false`.
    static func flagsDescription(_ entry: DebugStreamEntry) -> String {
        switch entry.source {
        case .cpu6510, .vic:
            var flags: [String] = []
            if entry.ba { flags.append("BA") }
            if !entry.irq { flags.append("IRQ") }
            if !entry.nmi { flags.append("NMI") }
            if !entry.rom { flags.append("ROM") }
            if !entry.exrom { flags.append("EXROM") }
            if !entry.game { flags.append("GAME") }
            return flags.joined(separator: " ")
        case .drive1541:
            var flags: [String] = []
            if entry.atn { flags.append("ATN") }
            if entry.clock { flags.append("CLK") }
            if entry.dataLine { flags.append("DATA") }
            if entry.sync { flags.append("SYNC") }
            if entry.byteReady { flags.append("BYTE_RDY") }
            if !entry.irq { flags.append("IRQ") }
            return flags.joined(separator: " ")
        }
    }
}

struct DebugTraceView: View {
    @ObservedObject var model: DebugTraceViewModel
    @ObservedObject var session: DeviceSession

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch model.displayMode {
            case .table: table
            case .memoryMap: MemoryMapView(heatmap: model.heatmap, source: model.activeSource)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $model.selectedMode) {
                ForEach(DebugStreamMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 190)
            .disabled(isBusy)

            startStopButton

            Divider().frame(height: 16)

            Picker("View", selection: $model.displayMode) {
                ForEach(DebugTraceDisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Toggle("Pause", isOn: $model.isPaused)
                .toggleStyle(.button)

            Button(model.isCapturing ? "Stop Capture & Export…" : "Start Capture") {
                model.toggleCapture()
            }
            .disabled(!isActive)

            Button("Export Visible as CSV…") {
                model.exportVisibleRowsAsCSV()
            }
            .disabled(model.rows.isEmpty)

            Spacer()

            statusLabel
        }
        .padding(10)
    }

    @ViewBuilder
    private var startStopButton: some View {
        switch session.debugTraceState {
        case .inactive, .error:
            Button("Start Trace", systemImage: "record.circle") {
                Task { await model.startTrace() }
            }
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…")
            }
        case .active:
            Button("Stop Trace", systemImage: "stop.circle") {
                Task { await model.stopTrace() }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isActive {
            Text("\(Int(model.wordsPerSecond)) words/s · \(model.missedPackets) missed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else if case .error(let message) = session.debugTraceState {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if let status = model.exportStatus {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var table: some View {
        Table(model.rows) {
            TableColumn("R/W") { row in
                Text(row.entry.isRead ? "R" : "W")
                    .foregroundStyle(row.entry.isRead ? Color.primary : Color.orange)
            }
            .width(30)
            TableColumn("Address") { row in
                Text("$" + String(format: "%04X", row.entry.address))
            }
            .width(70)
            TableColumn("Data") { row in
                Text("$" + String(format: "%02X", row.entry.data))
            }
            .width(60)
            TableColumn("PHI2") { row in
                Text(row.entry.phi2 ? "1" : "0")
            }
            .width(40)
            TableColumn("Flags") { row in
                Text(DebugTraceViewModel.flagsDescription(row.entry))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    private var isBusy: Bool {
        session.debugTraceState != .inactive
    }

    private var isActive: Bool {
        if case .active = session.debugTraceState { return true }
        return false
    }
}

@MainActor
final class DebugTraceWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: DebugTraceWindowController] = [:]

    private let deviceID: UUID
    private let model: DebugTraceViewModel

    static func show(session: DeviceSession) {
        if let existing = windows[session.device.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = DebugTraceWindowController(session: session)
        windows[session.device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.model.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(session: DeviceSession) {
        deviceID = session.device.id
        model = DebugTraceViewModel(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
            ],
            backing: .buffered, defer: false)
        window.title = "\(session.device.name) Debug Trace"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: DebugTraceView(model: model, session: session))
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.windows.removeValue(forKey: deviceID)
        Task { [model] in await model.stopTrace() }
    }
}
