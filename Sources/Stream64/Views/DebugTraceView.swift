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
    @Published var memoryMapVisualization: MemoryMapVisualization = .ioFade
    @Published var memoryMap3DOptions = MemoryMap3DOptions()
    let memoryMapRenderSettings = MemoryMapRenderSettings()
    let memoryMap3DInteraction = MemoryMap3DInteraction()
    @Published var isPaused = false
    @Published private(set) var isCapturing = false
    @Published private(set) var exportStatus: String?
    private var debugTraceLease: UUID?

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
        // Fire on the main RunLoop directly — nesting `Task { @MainActor }`
        // on every 200 ms tick can queue behind CRT presents.
        flushTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
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
        if let debugTraceLease {
            self.debugTraceLease = nil
            Task { await session.releaseDebugTrace(debugTraceLease) }
        }
    }

    private func flush() {
        guard !isPaused else { return }
        pendingLock.lock()
        let snapshot = pendingEntries
        pendingEntries.removeAll(keepingCapacity: true)
        pendingLock.unlock()
        guard !snapshot.isEmpty else { return }
        // Memory-map mode only needs the heatmap (updated in the entries
        // observer) — skip allocating table rows the UI will not show.
        guard displayMode != .memoryMap else { return }
        if session.isVideoGPUBehind { return }
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
        if debugTraceLease == nil {
            debugTraceLease = await session.acquireDebugTrace(mode: selectedMode)
        }
    }

    /// Opening the Debug Trace window is itself an intent to inspect the
    /// live trace. Start the selected stream automatically when nothing is
    /// running, but never restart/change a stream that is already active or
    /// in the process of starting (it may be shared by SID visualizations).
    func startTraceIfNeeded() async {
        switch session.debugTraceState {
        case .inactive, .error:
            await startTrace()
        case .starting, .active:
            break
        }
    }

    func stopTrace() async {
        if let debugTraceLease {
            self.debugTraceLease = nil
            await session.releaseDebugTrace(debugTraceLease)
        }
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
            switch model.displayMode {
            case .table: table
            case .memoryMap:
                MemoryMapView(
                    heatmap: model.heatmap,
                    source: model.activeSource,
                    visualization: model.memoryMapVisualization,
                    renderSettings: model.memoryMapRenderSettings,
                    threeDInteraction: model.memoryMap3DInteraction,
                    threeDOptions: model.memoryMap3DOptions,
                    videoGPUBehind: { session.isVideoGPUBehind })
            }
            if isActive || isErrored || model.exportStatus != nil {
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .toolbar { toolbarContent }
    }

    /// A thin status strip under the content instead of living inside the
    /// toolbar — the toolbar itself only holds controls now, and this only
    /// occupies space when there's actually something to say.
    private var statusBar: some View {
        HStack {
            statusLabel
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Moved from an in-content row into the window's native title-bar
    /// toolbar: that row used to cost a full extra strip of window height
    /// (padding + control height + a divider) purely for chrome, on top of
    /// the title bar the window already has. Action buttons are icon-only
    /// (with tooltips) rather than full-text labels — "Stop Capture &
    /// Export…"/"Export Visible as CSV…" alone were wider than the mode
    /// picker and the trace controls put together.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Mode", selection: $model.selectedMode) {
                ForEach(DebugStreamMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 160)
            .disabled(isBusy)
            .help("Which bus to trace")
        }

        ToolbarItem(placement: .navigation) {
            startStopButton
        }

        ToolbarItem {
            Picker("View", selection: $model.displayMode) {
                ForEach(DebugTraceDisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
        }

        if model.displayMode == .memoryMap {
            ToolbarItem {
                Menu {
                    ForEach(MemoryMapVisualization.allCases) { mode in
                        Button {
                            model.memoryMapVisualization = mode
                        } label: {
                            if model.memoryMapVisualization == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(
                        model.memoryMapVisualization.rawValue,
                        systemImage: "square.grid.3x3")
                }
                .help("Memory Map visualization")
            }

            if model.memoryMapVisualization == .ioFade {
                ToolbarItem {
                    MemoryMapDecayToolbarControl(
                        settings: model.memoryMapRenderSettings)
                    .help("How quickly recent memory activity fades")
                }
            }

            if model.memoryMapVisualization == .threeD {
                ToolbarItem {
                    Menu {
                        Toggle(
                            "Adaptive Detail",
                            isOn: $model.memoryMap3DOptions.adaptiveLOD)
                        Toggle(
                            "Hover Inspection",
                            isOn: $model.memoryMap3DOptions.hoverInspection)
                        Toggle(
                            "Region Overlays",
                            isOn: $model.memoryMap3DOptions.regionOverlays)
                        Toggle(
                            "Activity Pulse",
                            isOn: $model.memoryMap3DOptions.activityPulse)
                    } label: {
                        Label(
                            "3D Options",
                            systemImage: "slider.horizontal.3")
                    }
                    .help("Choose which 3D map enhancements are enabled")
                }

                ToolbarItem {
                    Button {
                        model.memoryMap3DInteraction.resetCamera()
                    } label: {
                        Label(
                            "Reset 3D View",
                            systemImage: "view.3d")
                    }
                    .help("Reset the 3D map rotation and zoom")
                }
            }

            ToolbarItem {
                HStack(spacing: 7) {
                    memoryMapLegend(color: .green, label: "Read")
                    memoryMapLegend(color: .orange, label: "Write")
                }
            }
        }

        ToolbarItem {
            Toggle(isOn: $model.isPaused) {
                Label("Pause", systemImage: "pause.fill")
            }
            .toggleStyle(.button)
            .help(model.isPaused ? "Resume updating" : "Pause updating")
        }

        ToolbarItem {
            Button {
                model.toggleCapture()
            } label: {
                Label(
                    model.isCapturing ? "Stop Capture & Export…" : "Start Capture",
                    systemImage: model.isCapturing ? "stop.circle" : "smallcircle.filled.circle")
            }
            .disabled(!isActive)
            .help(model.isCapturing
                  ? "Stop capturing and export the raw bytes"
                  : "Capture raw bytes for the official GtkWave pipeline")
        }

        ToolbarItem {
            Button {
                model.exportVisibleRowsAsCSV()
            } label: {
                Label("Export Visible as CSV…", systemImage: "square.and.arrow.up")
            }
            .disabled(model.rows.isEmpty)
            .help("Export the currently visible table rows as CSV")
        }
    }

    private func memoryMapLegend(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        switch session.debugTraceState {
        case .inactive, .error:
            Button {
                Task { await model.startTrace() }
            } label: {
                Label("Start Trace", systemImage: "record.circle")
            }
            .help("Start Trace")
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…")
            }
        case .active:
            Button {
                Task { await model.stopTrace() }
            } label: {
                Label("Stop Trace", systemImage: "stop.circle")
            }
            .help("Stop Trace")
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

    private var isErrored: Bool {
        if case .error = session.debugTraceState { return true }
        return false
    }
}

/// Native AppKit toolbar control for decay. An ordinary SwiftUI `Slider`
/// bound to an `@Published` view-model property invalidated the complete
/// Debug Trace hierarchy continuously while dragging; on this graphics-heavy
/// window that could destabilize compositing and corrupt the adjacent stream
/// view. This control updates only `MemoryMapRenderSettings.fadeDuration`.
private struct MemoryMapDecayToolbarControl: NSViewRepresentable {
    let settings: MemoryMapRenderSettings

    func makeNSView(context: Context) -> MemoryMapDecayNSView {
        MemoryMapDecayNSView(settings: settings)
    }

    func updateNSView(_ nsView: MemoryMapDecayNSView, context: Context) {
        nsView.settings = settings
    }
}

private final class MemoryMapDecayNSView: NSView {
    var settings: MemoryMapRenderSettings {
        didSet { synchronizeFromSettings() }
    }

    private let titleLabel = NSTextField(labelWithString: "Decay")
    private let slider = NSSlider(value: 0.15, minValue: 0.02, maxValue: 1, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "150 ms")

    init(settings: MemoryMapRenderSettings) {
        self.settings = settings
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.textColor = .secondaryLabelColor

        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)

        valueLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .left

        for view in [titleLabel, slider, valueLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 90),
            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        synchronizeFromSettings()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 24)
    }

    @objc private func sliderChanged() {
        settings.fadeDuration = slider.doubleValue
        valueLabel.stringValue = Self.formattedDuration(slider.doubleValue)
    }

    private func synchronizeFromSettings() {
        slider.doubleValue = settings.fadeDuration
        valueLabel.stringValue = Self.formattedDuration(settings.fadeDuration)
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        seconds < 1
            ? "\(Int(seconds * 1000)) ms"
            : String(format: "%.2f s", seconds)
    }
}

@MainActor
final class DebugTraceWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: DebugTraceWindowController] = [:]

    private var deviceID: UUID
    private var model: DebugTraceViewModel

    /// UI state preserved when auto-follow retargets the window to another
    /// machine (frame + display/visualization pickers).
    private struct FollowSnapshot {
        var frame: NSRect?
        var selectedMode: DebugStreamMode
        var displayMode: DebugTraceDisplayMode
        var memoryMapVisualization: MemoryMapVisualization
        var memoryMap3DOptions: MemoryMap3DOptions
        var fadeDuration: TimeInterval
    }

    static func show(session: DeviceSession) {
        if let existing = windows[session.device.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        present(session: session, restoring: nil)
    }

    /// Retarget any open Debug Trace / Memory Map window to `session` in
    /// place. Extra windows on other devices are closed; the kept window
    /// keeps its frame and visualization pickers.
    static func followSelectedSession(_ session: DeviceSession) {
        let open = Array(windows.values)
        guard !open.isEmpty else { return }
        if open.count == 1, open[0].deviceID == session.device.id { return }

        let source = open.first { $0.deviceID == session.device.id }
            ?? open.first { $0.window?.isKeyWindow == true }
            ?? open[0]
        for controller in open where controller !== source {
            controller.window?.close()
        }
        if source.deviceID == session.device.id { return }
        source.retarget(to: session)
    }

    private static func present(
        session: DeviceSession,
        restoring snapshot: FollowSnapshot?
    ) {
        let controller = DebugTraceWindowController(session: session)
        if let snapshot {
            controller.applyFollowSnapshot(snapshot)
        }
        windows[session.device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.model.start()
        Task { [model = controller.model] in
            await model.startTraceIfNeeded()
        }
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
        Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
    }

    required init?(coder: NSCoder) { nil }

    private func followSnapshot() -> FollowSnapshot {
        FollowSnapshot(
            frame: window?.frame,
            selectedMode: model.selectedMode,
            displayMode: model.displayMode,
            memoryMapVisualization: model.memoryMapVisualization,
            memoryMap3DOptions: model.memoryMap3DOptions,
            fadeDuration: model.memoryMapRenderSettings.fadeDuration)
    }

    private func applyFollowSnapshot(_ snapshot: FollowSnapshot) {
        model.selectedMode = snapshot.selectedMode
        model.displayMode = snapshot.displayMode
        model.memoryMapVisualization = snapshot.memoryMapVisualization
        model.memoryMap3DOptions = snapshot.memoryMap3DOptions
        model.memoryMapRenderSettings.fadeDuration = snapshot.fadeDuration
        if let frame = snapshot.frame {
            window?.setFrame(frame, display: false)
        }
    }

    private func retarget(to session: DeviceSession) {
        let snapshot = followSnapshot()
        let previousModel = model
        previousModel.stop()
        Task { await previousModel.stopTrace() }
        Self.windows.removeValue(forKey: deviceID)

        let newModel = DebugTraceViewModel(session: session)
        model = newModel
        deviceID = session.device.id
        window?.title = "\(session.device.name) Debug Trace"
        window?.contentViewController = NSHostingController(
            rootView: DebugTraceView(model: newModel, session: session))
        if let window {
            Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
        }
        applyFollowSnapshot(snapshot)
        Self.windows[session.device.id] = self
        newModel.start()
        Task { await newModel.startTraceIfNeeded() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.windows.removeValue(forKey: deviceID)
        Task { [model] in await model.stopTrace() }
    }
}
