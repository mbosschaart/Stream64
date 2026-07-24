import Foundation
import GameController

@MainActor
final class GameControllerManager {
    static let shared = GameControllerManager()

    private weak var target: C64InputController?
    private var observers: [NSObjectProtocol] = []

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
        target?.settings.connectedControllerName =
            GCController.controllers().first?.vendorName
    }

    private func configure(_ controller: GCController) {
        target?.settings.connectedControllerName = controller.vendorName
        if let pad = controller.extendedGamepad {
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                Task { @MainActor in
                    self?.applyAxes(
                        source: "gamepad-dpad", x: x, y: y)
                }
            }
            pad.leftThumbstick.valueChangedHandler = {
                [weak self] _, x, y in
                Task { @MainActor in
                    self?.applyAxes(
                        source: "gamepad-stick", x: x, y: y)
                }
            }
            pad.buttonA.pressedChangedHandler = {
                [weak self] _, _, pressed in
                Task { @MainActor in
                    self?.setFire(pressed)
                }
            }
        } else if let pad = controller.microGamepad {
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                Task { @MainActor in
                    self?.applyAxes(
                        source: "gamepad-dpad", x: x, y: y)
                }
            }
            pad.buttonA.pressedChangedHandler = {
                [weak self] _, _, pressed in
                Task { @MainActor in
                    self?.setFire(pressed)
                }
            }
        }
    }

    private func applyAxes(source: String, x: Float, y: Float) {
        guard let target,
              target.settings.gameControllerEnabled,
              target.settings.joystickEnabled else { return }
        let threshold = Float(target.settings.deadzone)
        target.setJoystick(
            source: source, input: .left, pressed: x < -threshold)
        target.setJoystick(
            source: source, input: .right, pressed: x > threshold)
        target.setJoystick(
            source: source, input: .up, pressed: y > threshold)
        target.setJoystick(
            source: source, input: .down, pressed: y < -threshold)
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
        target?.settings.connectedControllerName =
            GCController.controllers().first {
                $0 !== controller
            }?.vendorName
    }

    private func releaseControllerInputs() {
        guard let target else { return }
        for source in ["gamepad-dpad", "gamepad-stick", "gamepad-button"] {
            for input in JoystickDirection.allCases {
                target.setJoystick(
                    source: source, input: input, pressed: false)
            }
        }
    }
}
