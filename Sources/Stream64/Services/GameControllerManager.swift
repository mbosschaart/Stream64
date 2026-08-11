import Foundation
import GameController

@MainActor
final class GameControllerManager {
    static let shared = GameControllerManager()

    private weak var target: C64InputController?
    private var observers: [NSObjectProtocol] = []
    /// Latest analog samples awaiting a MainActor flush, keyed by source.
    /// Written from GameController callbacks (any queue) and drained on the
    /// main actor so rapid stick jitter collapses to one apply per turn.
    private let pendingAxes = PendingAxesBox()

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.configure(controller) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.disconnect(controller) }
        })
        GCController.startWirelessControllerDiscovery()
        for controller in GCController.controllers() {
            configure(controller)
        }
    }

    func setTarget(_ target: C64InputController?) {
        if self.target !== target {
            releaseControllerInputs()
        }
        self.target = target
        target?.settings.updateConnectedControllerName(
            GCController.controllers().first?.vendorName)
    }

    private func configure(_ controller: GCController) {
        target?.settings.updateConnectedControllerName(controller.vendorName)
        if let pad = controller.extendedGamepad {
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                self?.scheduleAxes(source: "gamepad-dpad", x: x, y: y)
            }
            pad.leftThumbstick.valueChangedHandler = {
                [weak self] _, x, y in
                self?.scheduleAxes(source: "gamepad-stick", x: x, y: y)
            }
            pad.buttonA.pressedChangedHandler = {
                [weak self] _, _, pressed in
                Task { @MainActor in
                    self?.setFire(pressed)
                }
            }
        } else if let pad = controller.microGamepad {
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                self?.scheduleAxes(source: "gamepad-dpad", x: x, y: y)
            }
            pad.buttonA.pressedChangedHandler = {
                [weak self] _, _, pressed in
                Task { @MainActor in
                    self?.setFire(pressed)
                }
            }
        }
    }

    private func scheduleAxes(source: String, x: Float, y: Float) {
        let shouldFlush = pendingAxes.store(source: source, x: x, y: y)
        guard shouldFlush else { return }
        Task { @MainActor in
            self.flushPendingAxes()
        }
    }

    private func flushPendingAxes() {
        let batch = pendingAxes.takeAll()
        for (source, sample) in batch {
            applyAxes(source: source, x: sample.x, y: sample.y)
        }
    }

    private func applyAxes(source: String, x: Float, y: Float) {
        guard let target,
              target.settings.gameControllerEnabled,
              target.settings.joystickEnabled else { return }
        let threshold = Float(target.settings.deadzone)
        target.setJoystickAxes(
            source: source,
            left: x < -threshold,
            right: x > threshold,
            up: y > threshold,
            down: y < -threshold)
    }

    private func setFire(_ pressed: Bool) {
        guard let target,
              target.settings.gameControllerEnabled,
              target.settings.joystickEnabled else { return }
        target.setJoystick(
            source: "gamepad-button", input: .fire, pressed: pressed)
    }

    private func disconnect(_ controller: GCController) {
        releaseControllerInputs()
        target?.settings.updateConnectedControllerName(
            GCController.controllers().first {
                $0 !== controller
            }?.vendorName)
    }

    private func releaseControllerInputs() {
        _ = pendingAxes.takeAll()
        guard let target else { return }
        for source in ["gamepad-dpad", "gamepad-stick"] {
            target.setJoystickAxes(
                source: source, left: false, right: false,
                up: false, down: false)
        }
        target.setJoystick(
            source: "gamepad-button", input: .fire, pressed: false)
    }
}

/// Thread-safe pending-axis buffer for GameController callbacks that may
/// arrive off the main actor. Latest sample per source wins.
private final class PendingAxesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (x: Float, y: Float)] = [:]
    private var flushScheduled = false

    /// Stores the sample. Returns `true` when the caller should schedule a
    /// MainActor flush (only the first pending write after a drain).
    func store(source: String, x: Float, y: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[source] = (x, y)
        guard !flushScheduled else { return false }
        flushScheduled = true
        return true
    }

    func takeAll() -> [String: (x: Float, y: Float)] {
        lock.lock()
        defer { lock.unlock() }
        let out = values
        values.removeAll(keepingCapacity: true)
        flushScheduled = false
        return out
    }
}
