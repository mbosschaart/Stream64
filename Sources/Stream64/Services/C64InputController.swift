import Foundation
import Combine

@MainActor
final class C64InputController: ObservableObject {
    private enum Command {
        case matrix(C64MachineInputEvent, fallback: [UInt8])
        case legacy([UInt8])
        case releaseAll
    }

    let settings: InputSettings
    private let client: UltimateAPIClient
    private let maximumQueueDepth: Int
    private var queue: [Command] = []
    private var queueHead = 0
    private var worker: Task<Void, Never>?
    private var workerGeneration = 0
    private var isTearingDown = false
    private var deferredCommands: [Command] = []
    private var matrixUnavailable = false
    private var heldKeys: [UInt16: (inputs: [String], fallback: UInt8?)] = [:]
    private var joystickSources: [String: Set<JoystickDirection>] = [:]
    private var emittedJoystick: Set<JoystickDirection> = []
    private var mouseFirmwareEligible = false
    private var mouseProbeGeneration = 0
    private var mouseAttached = false
    private var mouseButtons = Set<String>()
    private var mouseX = 0.0, mouseY = 0.0
    private var wheelX = 0.0, wheelY = 0.0
    private var mouseFlushTask: Task<Void, Never>?
    private var remoteMousePending = 0
    private var remoteMouseSampleTime = 0.0
    private var preferenceObservers = Set<AnyCancellable>()

    init(
        device: UltimateDevice,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        maximumQueueDepth: Int = 1024
    ) {
        settings = InputSettings.shared(for: device.id)
        client = UltimateAPIClient(device: device, transport: transport)
        self.maximumQueueDepth = maximumQueueDepth
        settings.$mouseEnabled.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.releaseAllIfNeeded() }
        }.store(in: &preferenceObservers)
        Publishers.MergeMany([settings.$buttonA, settings.$buttonB, settings.$buttonX, settings.$buttonY])
            .dropFirst(4).sink { [weak self] _ in self?.releaseAllIfNeeded() }
            .store(in: &preferenceObservers)
        Publishers.Merge(settings.$fire2Key, settings.$fire3Key)
            .dropFirst(2).sink { [weak self] _ in self?.releaseAllIfNeeded() }
            .store(in: &preferenceObservers)
        settings.$transport.dropFirst().sink { [weak self] transport in
            if transport == .legacy { self?.releaseAllIfNeeded() }
        }.store(in: &preferenceObservers)
    }

    var canCaptureMouse: Bool {
        settings.mouseEnabled && settings.mouseAvailable
            && settings.transport != .legacy && settings.capability == .supported && !isTearingDown
    }

    func setDeviceInfo(_ info: UltimateAPIClient.DeviceInfo) {
        invalidateMouseSupport()
        mouseFirmwareEligible = info.supportsRemoteMouseFirmware
    }

    func invalidateMouseSupport() {
        mouseProbeGeneration += 1
        mouseFirmwareEligible = false
        settings.updateMouseAvailability(false)
        if mouseAttached || mouseFlushTask != nil { releaseAll() }
    }

    func moveMouse(x: Double, y: Double) {
        guard canCaptureMouse, x.isFinite, y.isFinite else { return }
        // Bound unsent motion under transport stalls; never replay old movement.
        mouseX = min(254, max(-254, mouseX + x))
        mouseY = min(254, max(-254, mouseY + y))
        scheduleMouseFlush()
    }

    func scrollMouse(horizontal: Double, vertical: Double) {
        guard canCaptureMouse, horizontal.isFinite, vertical.isFinite else { return }
        wheelX = min(8, max(-8, wheelX + horizontal))
        wheelY = min(8, max(-8, wheelY + vertical))
        scheduleMouseFlush()
    }

    func mouseButton(_ button: String, pressed: Bool) {
        guard canCaptureMouse, ["left", "right", "middle"].contains(button) else { return }
        if pressed {
            guard mouseButtons.insert(button).inserted else { return }
        } else {
            guard mouseButtons.remove(button) != nil else { return }
        }
        flushMouseMotion()
        mouseAttached = true
        enqueue(.matrix(.mouseButton(button, transition: pressed ? .press : .release), fallback: []))
    }

    private func scheduleMouseFlush() {
        guard mouseFlushTask == nil else { return }
        mouseFlushTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            guard let self else { return }
            self.mouseFlushTask = nil
            self.flushMouseMotion()
            if abs(self.mouseX) >= 1 || abs(self.mouseY) >= 1
                || abs(self.wheelX) >= 1 || abs(self.wheelY) >= 1 {
                self.scheduleMouseFlush()
            }
        }
    }

    private func flushMouseMotion() {
        guard canCaptureMouse else { clearMouseState(); return }
        let drained = Int(max(0, ProcessInfo.processInfo.systemUptime - remoteMouseSampleTime) / 0.02)
        guard logicalQueueDepth < 4, max(0, remoteMousePending - drained) < 4 else {
            mouseX = 0; mouseY = 0; wheelX = 0; wheelY = 0
            return
        }
        let x = min(127, max(-127, Int(mouseX)))
        let y = min(127, max(-127, Int(mouseY)))
        mouseX -= Double(x); mouseY -= Double(y)
        if x != 0 || y != 0 {
            mouseAttached = true
            enqueue(.matrix(.mouseMove(x: x, y: y), fallback: []))
        }
        // One detent per axis per tick prevents a scroll gesture from queuing
        // seconds of firmware reports (each report takes at least 20 ms).
        let h = min(1, max(-1, Int(wheelX)))
        let v = min(1, max(-1, Int(wheelY)))
        wheelX -= Double(h); wheelY -= Double(v)
        if h != 0 || v != 0 {
            mouseAttached = true
            enqueue(.matrix(.mouseWheel(vertical: v, horizontal: h), fallback: []))
        }
    }

    private func clearMouseState() {
        mouseFlushTask?.cancel()
        mouseFlushTask = nil
        mouseX = 0; mouseY = 0; wheelX = 0; wheelY = 0
        mouseButtons.removeAll()
        mouseAttached = false
        remoteMousePending = 0
        remoteMouseSampleTime = ProcessInfo.processInfo.systemUptime
    }

    func prepare() async {
        do {
            let status = try await client.ensureInputServicesEnabled()
            settings.servicesReady =
                status.dmaEnabled && status.webRemoteEnabled
        } catch {
            settings.servicesReady = false
        }
        await probeCapability()
    }

    func probeCapability() async {
        mouseProbeGeneration += 1
        let mouseGeneration = mouseProbeGeneration
        settings.updateMouseAvailability(false)
        if mouseAttached || mouseFlushTask != nil {
            await cancelAndRelease()
            guard mouseGeneration == mouseProbeGeneration else { return }
        }
        guard settings.transport != .legacy else {
            settings.updateCapability(.legacyFallback)
            matrixUnavailable = true
            return
        }
        settings.updateCapability(.probing)
        do {
            try await client.releaseAllInput()
            guard mouseGeneration == mouseProbeGeneration else { return }
            matrixUnavailable = false
            settings.updateCapability(.supported)
            if mouseFirmwareEligible {
                let state = try? await client.fetchMachineInputState()
                guard mouseGeneration == mouseProbeGeneration else { return }
                settings.updateMouseAvailability(state?.mouse != nil)
            }
        } catch {
            guard mouseGeneration == mouseProbeGeneration else { return }
            if Self.isUnsupported(error) {
                matrixUnavailable = true
                settings.joystickEnabled = false
                settings.updateCapability(.unsupported(
                    "Firmware has no matrix input; keyboard uses legacy mode"))
            } else {
                settings.updateCapability(.failed(error.localizedDescription))
            }
        }
    }

    func tapPETSCII(_ codes: [UInt8]) {
        for code in codes {
            if let chord = C64MatrixMapper.chord(for: code) {
                enqueue(.matrix(
                    .keyboard(chord, transition: .tap),
                    fallback: [code]))
            } else {
                enqueue(.legacy([code]))
            }
        }
    }

    func typeAndWait(_ codes: [UInt8]) async {
        tapPETSCII(codes)
        while worker != nil || queueHead < queue.count {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func keyDown(
        hostKeyCode: UInt16,
        inputs: [String],
        fallback: UInt8?,
        holdable: Bool
    ) {
        guard heldKeys[hostKeyCode] == nil else { return }
        if holdable {
            heldKeys[hostKeyCode] = (inputs, fallback)
            enqueue(.matrix(
                .keyboard(inputs, transition: .press),
                fallback: fallback.map { [$0] } ?? []))
        } else {
            enqueue(.matrix(
                .keyboard(inputs, transition: .tap),
                fallback: fallback.map { [$0] } ?? []))
        }
    }

    func keyUp(hostKeyCode: UInt16) {
        guard let held = heldKeys.removeValue(
            forKey: hostKeyCode) else { return }
        enqueue(.matrix(
            .keyboard(held.inputs, transition: .release),
            fallback: []))
    }

    func isHostKeyHeld(_ keyCode: UInt16) -> Bool {
        heldKeys[keyCode] != nil
    }

    func setJoystick(
        source: String,
        input: JoystickDirection,
        pressed: Bool
    ) {
        var state = joystickSources[source] ?? []
        if pressed {
            guard state.insert(input).inserted else { return }
        } else {
            guard state.remove(input) != nil else { return }
        }
        joystickSources[source] = state
        emitMergedJoystick()
    }

    /// Replaces the directional state for one gamepad source (D-pad or
    /// stick) in a single merge pass. No-ops when the four direction bits
    /// are unchanged so high-rate analog callbacks don't thrash the queue.
    func setJoystickAxes(
        source: String,
        left: Bool,
        right: Bool,
        up: Bool,
        down: Bool
    ) {
        var next = Set<JoystickDirection>()
        if left { next.insert(.left) }
        if right { next.insert(.right) }
        if up { next.insert(.up) }
        if down { next.insert(.down) }
        let previous = joystickSources[source] ?? []
        guard previous != next else { return }
        if next.isEmpty {
            joystickSources.removeValue(forKey: source)
        } else {
            joystickSources[source] = next
        }
        emitMergedJoystick()
    }

    func toggleJoystickMode() {
        guard settings.capability == .supported else {
            settings.joystickEnabled = false
            return
        }
        releaseAll()
        settings.joystickEnabled.toggle()
    }

    func toggleJoystickPort() {
        releaseAll()
        settings.joystickPort = settings.joystickPort == 1 ? 2 : 1
    }

    func releaseAll() {
        clearMouseState()
        // Discard stale queued mouse reports before the detach barrier.
        let remaining = queue.dropFirst(queueHead).filter {
            if case .matrix(let event, _) = $0 { return event.kind != .mouse }
            return true
        }
        queue = Array(remaining)
        queueHead = 0
        heldKeys.removeAll()
        joystickSources.removeAll()
        emittedJoystick.removeAll()
        enqueue(.releaseAll)
    }

    /// Focus transitions occur whenever a tool/visualization window opens.
    /// Do not send a remote `release_all` unless this controller actually
    /// owns held or queued input—some RSID players are sensitive to unrelated
    /// input API traffic while running.
    func releaseAllIfNeeded() {
        guard !heldKeys.isEmpty
            || mouseAttached || mouseFlushTask != nil
            || !joystickSources.isEmpty
            || !emittedJoystick.isEmpty
            || logicalQueueDepth > 0
        else { return }
        releaseAll()
    }

    func cancelAndRelease() async {
        guard !isTearingDown else { return }
        isTearingDown = true
        clearMouseState()
        heldKeys.removeAll()
        joystickSources.removeAll()
        emittedJoystick.removeAll()
        queue.removeAll()
        queueHead = 0
        let previous = worker
        worker?.cancel()
        workerGeneration += 1
        worker = nil
        // Wait for any in-flight matrix/legacy HTTP to finish so release-all
        // is always the last remote op (otherwise a late batch can re-press).
        if let previous {
            await previous.value
        }
        await sendReleaseAllWithRetry()
        try? await client.flushKeyboardBuffer()
        isTearingDown = false
        queue = deferredCommands
        deferredCommands.removeAll(keepingCapacity: true)
        queueHead = 0
        startWorker()
    }

    private func emitMergedJoystick() {
        var merged = joystickSources.values.reduce(
            into: Set<JoystickDirection>()) { $0.formUnion($1) }
        if merged.contains(.left) && merged.contains(.right) {
            merged.remove(.left)
            merged.remove(.right)
        }
        if merged.contains(.up) && merged.contains(.down) {
            merged.remove(.up)
            merged.remove(.down)
        }
        for released in emittedJoystick.subtracting(merged) {
            enqueue(.matrix(
                .joystick(
                    released.rawValue, port: settings.joystickPort,
                    transition: .release),
                fallback: []))
        }
        for pressed in merged.subtracting(emittedJoystick) {
            enqueue(.matrix(
                .joystick(
                    pressed.rawValue, port: settings.joystickPort,
                    transition: .press),
                fallback: []))
        }
        emittedJoystick = merged
    }

    private var logicalQueueDepth: Int { queue.count - queueHead }

    private func enqueue(_ command: Command) {
        if isTearingDown {
            deferredCommands.append(command)
            return
        }
        guard logicalQueueDepth + deferredCommands.count < maximumQueueDepth else {
            settings.updateCapability(.failed("Input queue is full"))
            // Never silently drop a release or leave presses that are
            // already remote-active. Throw away stale work and make the
            // next operation a release-all recovery.
            scheduleEmergencyRelease()
            return
        }
        queue.append(command)
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, queueHead < queue.count else { return }
        let generation = workerGeneration
        worker = Task { [weak self] in
            await self?.drain()
            guard let self else { return }
            guard self.workerGeneration == generation else { return }
            self.worker = nil
            self.startWorker()
        }
    }

    private func drain() async {
        while queueHead < queue.count, !Task.isCancelled {
            switch queue[queueHead] {
            case .legacy(let bytes):
                queueHead += 1
                do {
                    try await client.typeKeys(bytes)
                } catch {
                    settings.updateCapability(
                        .failed(error.localizedDescription))
                }
            case .releaseAll:
                queueHead += 1
                await sendReleaseAllWithRetry()
                try? await client.flushKeyboardBuffer()
            case .matrix:
                var events: [C64MachineInputEvent] = []
                var fallback: [UInt8] = []
                // Even verbose keyboard chords stay inside the firmware's
                // independent 4096-byte body limit with this batch size.
                while events.count < 16, queueHead < queue.count {
                    guard case .matrix(let event, let bytes) = queue[queueHead] else {
                        break
                    }
                    queueHead += 1
                    events.append(event)
                    fallback.append(contentsOf: bytes)
                }
                await sendMatrixBatch(events, fallback: fallback)
            }
        }
        if queueHead > 256 {
            queue.removeFirst(queueHead)
            queueHead = 0
        } else if queueHead == queue.count {
            queue.removeAll(keepingCapacity: true)
            queueHead = 0
        }
    }

    private func sendMatrixBatch(
        _ events: [C64MachineInputEvent],
        fallback: [UInt8]
    ) async {
        if settings.transport == .legacy || matrixUnavailable {
            if !fallback.isEmpty { try? await client.typeKeys(fallback) }
            return
        }
        do {
            let state = try await client.sendMachineInput(events)
            if let mouse = state?.mouse {
                remoteMousePending = mouse.pending
                remoteMouseSampleTime = ProcessInfo.processInfo.systemUptime
            }
            // Probe already established support — don't republish on every
            // successful joystick/keyboard batch (that rebuilds the viewer).
            settings.updateCapability(.supported)
        } catch {
            if settings.transport == .auto, Self.isUnsupported(error) {
                matrixUnavailable = true
                settings.updateCapability(.legacyFallback)
                if !fallback.isEmpty { try? await client.typeKeys(fallback) }
            } else {
                settings.updateCapability(
                    .failed(error.localizedDescription))
                // The batch has already left the local queue. Its remote
                // outcome is unknown, so individual releases are no longer
                // reliable — force a global release before accepting more
                // presses.
                scheduleEmergencyRelease()
            }
        }
    }

    private func scheduleEmergencyRelease() {
        clearMouseState()
        heldKeys.removeAll()
        joystickSources.removeAll()
        emittedJoystick.removeAll()
        queue.removeAll()
        queueHead = 0
        queue.append(.releaseAll)
        startWorker()
    }

    private func sendReleaseAllWithRetry() async {
        guard !matrixUnavailable else { return }
        for attempt in 0..<3 {
            do {
                try await client.releaseAllInput()
                return
            } catch {
                if attempt == 2 {
                    settings.updateCapability(.failed(
                        "Could not release C64 input: "
                        + error.localizedDescription))
                } else {
                    try? await Task.sleep(for: .milliseconds(
                        100 * (attempt + 1)))
                }
            }
        }
    }

    private static func isUnsupported(_ error: Error) -> Bool {
        guard case UltimateAPIClient.APIError.httpError(
            let code, _
        ) = error else { return false }
        return [404, 405, 501].contains(code)
    }
}

enum C64MatrixMapper {
    static func chord(for code: UInt8) -> [String]? {
        switch code {
        case 0x41...0x5A:
            return [String(UnicodeScalar(code + 0x20))]
        case 0xC1...0xDA:
            return ["left_shift", String(UnicodeScalar(code - 0x80 + 0x20))]
        case 0x30...0x39:
            return [String(UnicodeScalar(code))]
        case 0x21...0x29:
            return ["left_shift", String(UnicodeScalar(code + 0x10))]
        case 0x20: return ["space"]
        case 0x0D: return ["return"]
        case 0x03: return ["run_stop"]
        case 0x11: return ["cursor_up_down"]
        case 0x91: return ["left_shift", "cursor_up_down"]
        case 0x1D: return ["cursor_left_right"]
        case 0x9D: return ["left_shift", "cursor_left_right"]
        case 0x13: return ["clr_home"]
        case 0x93: return ["left_shift", "clr_home"]
        case 0x14: return ["inst_del"]
        case 0x94: return ["left_shift", "inst_del"]
        case 0x2B: return ["plus"]
        case 0x2D: return ["minus"]
        case 0x2A: return ["star"]
        case 0x3D: return ["equals"]
        case 0x2C: return ["comma"]
        case 0x2E: return ["period"]
        case 0x2F: return ["slash"]
        case 0x3A: return ["colon"]
        case 0x3B: return ["semicolon"]
        case 0x40: return ["at"]
        case 0x5C: return ["pound"]
        case 0x5E: return ["arrow_up"]
        case 0x5F: return ["arrow_left"]
        case 0x5B: return ["left_shift", "colon"]
        case 0x5D: return ["left_shift", "semicolon"]
        case 0x85: return ["f1"]
        case 0x89: return ["left_shift", "f1"]
        case 0x86: return ["f3"]
        case 0x8A: return ["left_shift", "f3"]
        case 0x87: return ["f5"]
        case 0x8B: return ["left_shift", "f5"]
        case 0x88: return ["f7"]
        case 0x8C: return ["left_shift", "f7"]
        default: return nil
        }
    }
}
