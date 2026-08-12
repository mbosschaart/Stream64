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
    private var matrixUnavailable = false
    private var heldKeys: [UInt16: (inputs: [String], fallback: UInt8?)] = [:]
    private var joystickSources: [String: Set<JoystickDirection>] = [:]
    private var emittedJoystick: Set<JoystickDirection> = []

    init(
        device: UltimateDevice,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        maximumQueueDepth: Int = 1024
    ) {
        settings = InputSettings.shared(for: device.id)
        client = UltimateAPIClient(device: device, transport: transport)
        self.maximumQueueDepth = maximumQueueDepth
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
        guard settings.transport != .legacy else {
            settings.updateCapability(.legacyFallback)
            matrixUnavailable = true
            return
        }
        settings.updateCapability(.probing)
        do {
            try await client.releaseAllInput()
            matrixUnavailable = false
            settings.updateCapability(.supported)
        } catch {
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
        heldKeys.removeAll()
        joystickSources.removeAll()
        emittedJoystick.removeAll()
        enqueue(.releaseAll)
    }

    func cancelAndRelease() async {
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
        guard logicalQueueDepth < maximumQueueDepth else {
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
                while events.count < 64, queueHead < queue.count {
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
            try await client.sendMachineInput(events)
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
