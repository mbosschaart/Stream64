import XCTest
import CryptoKit
import ZIPFoundation
import MetalKit
import AVFoundation
@testable import Stream64

final class InputTests: XCTestCase {
    @MainActor
    func testFocusReleaseSkipsRemoteCallWhenNoInputIsHeld() async throws {
        let transport = RecordingHTTPTransport()
        let controller = C64InputController(
            device: UltimateDevice(
                id: UUID(), name: "Input", host: "192.168.1.64"),
            transport: transport)
        controller.settings.transport = .matrix

        controller.releaseAllIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        let noInputRequest = await transport.recordedRequest()
        XCTAssertNil(noInputRequest)

        controller.keyDown(
            hostKeyCode: 0,
            inputs: ["a"],
            fallback: 0x41,
            holdable: true)
        controller.releaseAllIfNeeded()
        for _ in 0..<20 where await transport.recordedRequest() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let recordedRequest = await transport.recordedRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertTrue([
            "/v1/machine:input",
            "/v1/machine:writemem",
        ].contains(request.url?.path))
    }

    func testMachineInputRequestAndServiceAutoEnable() async throws {
        let transport = ScriptedInputTransport()
        let device = UltimateDevice(name: "Input", host: "192.168.1.64")
        let client = UltimateAPIClient(
            device: device, transport: transport)

        let status = try await client.ensureInputServicesEnabled()
        XCTAssertTrue(status.changed)
        try await client.sendMachineInput([
            .keyboard(["left_shift", "1"], transition: .tap),
            .joystick("left", port: 2, transition: .press),
        ])

        let requests = await transport.requests
        XCTAssertTrue(requests.contains {
            $0.url?.path.contains("Ultimate DMA Service") == true
        })
        XCTAssertTrue(requests.contains {
            $0.url?.path == "/v1/configs:save_to_flash"
        })
        let inputRequest = try XCTUnwrap(requests.last {
            $0.url?.path == "/v1/machine:input"
        })
        XCTAssertEqual(inputRequest.httpMethod, "POST")
        let envelope = try JSONDecoder().decode(
            C64MachineInputEnvelope.self,
            from: try XCTUnwrap(inputRequest.httpBody))
        XCTAssertEqual(envelope.events.count, 2)
        XCTAssertEqual(envelope.events[1].port, 2)
        XCTAssertEqual(envelope.events[1].inputs, ["left"])
    }


    @MainActor
    func testHostKeyMappingAndJoystickTransitions() async throws {
        let device = UltimateDevice(
            id: UUID(), name: "Input", host: "192.168.1.64")
        let transport = ScriptedInputTransport()
        let controller = C64InputController(
            device: device, transport: transport)
        controller.settings.transport = .matrix
        controller.settings.keymap = .symbolic
        controller.settings.joystickEnabled = true

        let arrow = HostKeyInput(
            keyCode: 123, characters: nil,
            modifiers: [], isRepeat: false)
        XCTAssertEqual(
            C64HostKeyMapper.action(
                for: arrow, settings: controller.settings),
            .joystick(.left))
        let backquote = HostKeyInput(
            keyCode: 50, characters: "`",
            modifiers: [], isRepeat: false)
        XCTAssertEqual(
            C64HostKeyMapper.action(
                for: backquote, settings: controller.settings),
            .joystick(.fire))
        let space = HostKeyInput(
            keyCode: 49, characters: " ",
            modifiers: [], isRepeat: false)
        XCTAssertEqual(
            C64HostKeyMapper.action(
                for: space, settings: controller.settings),
            .key(C64KeyBinding(
                inputs: ["space"], fallback: 0x20,
                holdable: true)))
        XCTAssertEqual(
            C64HostKeyMapper.joystickModifier(
                keyCode: 55, modifiers: [.command], enabled: true,
                fireKey: .command)?.input,
            .fire)
        XCTAssertEqual(
            C64HostKeyMapper.joystickModifier(
                keyCode: 55, modifiers: [], enabled: true,
                fireKey: .command)?.pressed,
            false)

        controller.setJoystick(
            source: "keyboard", input: .left, pressed: true)
        controller.setJoystick(
            source: "gamepad", input: .right, pressed: true)
        controller.setJoystick(
            source: "gamepad", input: .right, pressed: false)
        for _ in 0..<100 {
            if await transport.inputEventCount >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await transport.allInputEvents
        XCTAssertTrue(events.contains {
            $0.inputs == ["left"] && $0.transition == .press
        })
        XCTAssertTrue(events.contains {
            $0.inputs == ["left"] && $0.transition == .release
        })

        let countAfterEdges = await transport.inputEventCount
        // Held left is already emitted — repeating it and an unchanged
        // stick sample must not enqueue anything new.
        controller.setJoystick(
            source: "keyboard", input: .left, pressed: true)
        controller.setJoystickAxes(
            source: "gamepad-stick",
            left: false, right: false, up: false, down: false)
        controller.setJoystickAxes(
            source: "gamepad-stick",
            left: false, right: false, up: true, down: false)
        controller.setJoystickAxes(
            source: "gamepad-stick",
            left: false, right: false, up: true, down: false)
        for _ in 0..<100 {
            if await transport.inputEventCount >= countAfterEdges + 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let afterRedundant = await transport.allInputEvents
        XCTAssertEqual(
            afterRedundant.filter {
                $0.inputs == ["up"] && $0.transition == .press
            }.count,
            1)
        let countAfterRedundant = await transport.inputEventCount
        XCTAssertEqual(
            countAfterRedundant,
            countAfterEdges + 1,
            "redundant joystick updates must not enqueue extra events")

        controller.keyDown(
            hostKeyCode: 0, inputs: ["a"],
            fallback: 0x41, holdable: true)
        controller.keyDown(
            hostKeyCode: 0, inputs: ["a"],
            fallback: 0x41, holdable: true)
        controller.keyUp(hostKeyCode: 0)
        controller.releaseAll()
        for _ in 0..<100 {
            if await transport.inputEventCount >= 6 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalEvents = await transport.allInputEvents
        XCTAssertEqual(finalEvents.filter {
            $0.inputs == ["a"] && $0.transition == .press
        }.count, 1)
        XCTAssertEqual(finalEvents.filter {
            $0.inputs == ["a"] && $0.transition == .release
        }.count, 1)
        XCTAssertTrue(finalEvents.contains { $0.kind == .releaseAll })
    }


    func testPETSCIIToMatrixAndCustomKeymapParsing() throws {
        XCTAssertEqual(
            C64MatrixMapper.chord(for: 0x21),
            ["left_shift", "1"])
        XCTAssertEqual(
            C64MatrixMapper.chord(for: 0x91),
            ["left_shift", "cursor_up_down"])
        let keymap = try C64KeymapFile.parse("""
        [meta]
        name=Test Map
        type=positional
        [map]
        KeyA=0x41
        Shift+KeyA=0xC1
        """)
        XCTAssertEqual(keymap.name, "Test Map")
        XCTAssertEqual(keymap.type, .positional)
        XCTAssertEqual(keymap.mappings["KeyA"], 0x41)
    }


    @MainActor
    func testInputCapabilityDoesNotRepublishOnSuccessfulSends() async throws {
        let device = UltimateDevice(
            id: UUID(), name: "Input", host: "192.168.1.64")
        let transport = ScriptedInputTransport()
        let controller = C64InputController(
            device: device, transport: transport)
        controller.settings.transport = .matrix
        controller.settings.updateCapability(.supported)

        var publishCount = 0
        let token = controller.settings.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { token.cancel() }

        controller.setJoystick(
            source: "keyboard", input: .left, pressed: true)
        controller.setJoystick(
            source: "keyboard", input: .left, pressed: false)
        for _ in 0..<100 {
            if await transport.inputEventCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Successful matrix sends must not churn InputSettings while already
        // marked supported — that used to rebuild the live viewer every batch.
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(controller.settings.capability, .supported)
    }


    @MainActor
    func testCancelAndReleaseAwaitsInFlightMatrixBeforeReleaseAll() async throws {
        let transport = DelayedInputTransport()
        let device = UltimateDevice(name: "Delay", host: "192.0.2.1")
        let controller = C64InputController(
            device: device, transport: transport, maximumQueueDepth: 16)
        controller.settings.updateCapability(.supported)

        controller.keyDown(
            hostKeyCode: 0, inputs: ["a"], fallback: 0x41, holdable: true)
        // Give the worker time to enter the delayed HTTP send.
        try await Task.sleep(for: .milliseconds(50))
        let releaseTask = Task { await controller.cancelAndRelease() }
        try await Task.sleep(for: .milliseconds(30))
        await transport.releaseDelayedRequest()
        await releaseTask.value
        let released = await transport.hasReleaseAll()
        XCTAssertTrue(released)
    }

    @MainActor
    func testCancelAndReleaseDefersNewInputUntilAfterReleaseAll() async throws {
        let transport = DelayedInputTransport()
        let device = UltimateDevice(name: "Delay", host: "192.0.2.1")
        let controller = C64InputController(
            device: device, transport: transport, maximumQueueDepth: 16)
        controller.settings.updateCapability(.supported)

        controller.keyDown(
            hostKeyCode: 0, inputs: ["a"], fallback: 0x41, holdable: true)
        try await Task.sleep(for: .milliseconds(50))
        let releaseTask = Task { await controller.cancelAndRelease() }
        try await Task.sleep(for: .milliseconds(30))
        controller.keyDown(
            hostKeyCode: 11, inputs: ["b"], fallback: 0x42, holdable: true)
        let initialOrder = await transport.recordedCommandOrder()
        XCTAssertEqual(initialOrder, ["press"])

        await transport.releaseDelayedRequest()
        for _ in 0..<100 {
            if await transport.recordedCommandOrder().count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalOrder = await transport.recordedCommandOrder()
        XCTAssertEqual(finalOrder, ["press", "release_all", "press"])
        await transport.releaseDelayedRequest()
        await releaseTask.value
    }

    @MainActor
    func testInputFailureTriggersReleaseAllRecovery() async throws {
        let transport = FailingPressInputTransport()
        let device = UltimateDevice(
            name: "Input",
            host: "192.0.2.1")
        let controller = C64InputController(
            device: device,
            transport: transport)

        controller.keyDown(
            hostKeyCode: 4,
            inputs: ["a"],
            fallback: 0x41,
            holdable: true)

        for _ in 0..<100 {
            if await transport.sawReleaseAll { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let recovered = await transport.hasReleaseAll()
        XCTAssertTrue(
            recovered,
            "ambiguous failed press must be followed by release_all")
        XCTAssertFalse(controller.isHostKeyHeld(4))
    }


    @MainActor
    func testInputQueueOverflowTriggersReleaseAllRecovery() async throws {
        let transport = DelayedInputTransport()
        let device = UltimateDevice(
            name: "Input",
            host: "192.0.2.1")
        let controller = C64InputController(
            device: device,
            transport: transport,
            maximumQueueDepth: 1)

        controller.keyDown(
            hostKeyCode: 4,
            inputs: ["a"],
            fallback: 0x41,
            holdable: true)
        controller.keyDown(
            hostKeyCode: 5,
            inputs: ["b"],
            fallback: 0x42,
            holdable: true)
        controller.keyDown(
            hostKeyCode: 6,
            inputs: ["c"],
            fallback: 0x43,
            holdable: true)

        await transport.releaseDelayedRequest()
        for _ in 0..<100 {
            if await transport.sawReleaseAll { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let recovered = await transport.hasReleaseAll()
        XCTAssertTrue(
            recovered,
            "overflow must be collapsed into release_all")
        XCTAssertFalse(controller.isHostKeyHeld(4))
        XCTAssertFalse(controller.isHostKeyHeld(5))
        XCTAssertFalse(controller.isHostKeyHeld(6))
    }


    @MainActor
    func testLegacyInputClearsStopFlagAndWritesOrderedBuffer() async throws {
        let device = UltimateDevice(
            id: UUID(), name: "Legacy", host: "192.168.1.64")
        let transport = ScriptedInputTransport()
        let controller = C64InputController(
            device: device, transport: transport)
        controller.settings.transport = .legacy
        controller.tapPETSCII([0x41])
        for _ in 0..<100 {
            if await transport.requests.count >= 5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await transport.requests
        let writeAddresses = requests.compactMap { request -> String? in
            guard request.url?.path == "/v1/machine:writemem" else {
                return nil
            }
            return URLComponents(
                url: request.url!,
                resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "address" }?.value
        }
        XCTAssertTrue(writeAddresses.contains("0091"))
        XCTAssertTrue(writeAddresses.contains("0277"))
        XCTAssertTrue(writeAddresses.contains("00C6"))
    }


    func testLiveMatrixInputCapabilityWhenConfigured() async throws {
        guard let host = ProcessInfo.processInfo.environment[
            "UV_LIVE_INPUT_HOST"
        ] else {
            throw XCTSkip("Set UV_LIVE_INPUT_HOST for live input probing")
        }
        let client = UltimateAPIClient(
            device: UltimateDevice(name: "Input Probe", host: host))
        let services = try await client.ensureInputServicesEnabled()
        XCTAssertTrue(services.dmaEnabled)
        XCTAssertTrue(services.webRemoteEnabled)
        do {
            try await client.releaseAllInput()
        } catch UltimateAPIClient.APIError.httpError(let code, _) {
            XCTAssertTrue([404, 405, 501].contains(code))
        }
    }


}
