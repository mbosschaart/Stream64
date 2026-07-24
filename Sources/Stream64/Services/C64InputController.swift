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
    private var queue: [Command] = []
    private var worker: Task<Void, Never>?
    private var matrixUnavailable = false
    private var heldKeys: [UInt16: (inputs: [String], fallback: UInt8?)] = [:]
    private var joystickSources: [String: Set<JoystickDirection>] = [:]
    private var emittedJoystick: Set<JoystickDirection> = []

    init(
        device: UltimateDevice,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        settings = InputSettings.shared(for: device.id)
        client = UltimateAPIClient(device: device, transport: transport)
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
            settings.capability = .legacyFallback
            matrixUnavailable = true
            return
        }
        settings.capability = .probing
        do {
            try await client.releaseAllInput()
            matrixUnavailable = false
            settings.capability = .supported
        } catch {
            if Self.isUnsupported(error) {
                matrixUnavailable = true
                settings.joystickEnabled = false
                settings.capability = .unsupported(
                    "Firmware has no matrix input; keyboard uses legacy mode")
            } else {
                settings.capability = .failed(error.localizedDescription)
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
        while worker != nil || !queue.isEmpty {
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
        if pressed { state.insert(input) } else { state.remove(input) }
        joystickSources[source] = state
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
        worker?.cancel()
        worker = nil
        try? await client.releaseAllInput()
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

    private func enqueue(_ command: Command) {
        guard queue.count < 1024 else {
            settings.capability = .failed("Input queue is full")
            return
        }
        queue.append(command)
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drain()
            guard let self else { return }
            self.worker = nil
            self.startWorker()
        }
    }

    private func drain() async {
        while !queue.isEmpty, !Task.isCancelled {
            switch queue[0] {
            case .legacy(let bytes):
                queue.removeFirst()
                do {
                    try await client.typeKeys(bytes)
                } catch {
                    settings.capability = .failed(error.localizedDescription)
                }
            case .releaseAll:
                queue.removeFirst()
                if !matrixUnavailable {
                    try? await client.releaseAllInput()
                }
                try? await client.flushKeyboardBuffer()
            case .matrix:
                var events: [C64MachineInputEvent] = []
                var fallback: [UInt8] = []
                while events.count < 64, !queue.isEmpty {
                    guard case .matrix(let event, let bytes) = queue[0] else {
                        break
                    }
                    queue.removeFirst()
                    events.append(event)
                    fallback.append(contentsOf: bytes)
                }
                await sendMatrixBatch(events, fallback: fallback)
            }
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
            settings.capability = .supported
        } catch {
            if settings.transport == .auto, Self.isUnsupported(error) {
                matrixUnavailable = true
                settings.capability = .legacyFallback
                if !fallback.isEmpty { try? await client.typeKeys(fallback) }
            } else {
                settings.capability = .failed(error.localizedDescription)
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
