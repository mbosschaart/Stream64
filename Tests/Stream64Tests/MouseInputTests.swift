import XCTest
@testable import Stream64

private actor MouseInputTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let hasMouse: Bool
    let stateDelay: Duration
    let postDelay: Duration
    let pending: Int

    init(hasMouse: Bool = true, stateDelay: Duration = .zero, postDelay: Duration = .zero, pending: Int = 0) {
        self.hasMouse = hasMouse
        self.stateDelay = stateDelay
        self.postDelay = postDelay
        self.pending = pending
    }

    var events: [C64MachineInputEvent] {
        requests.compactMap(\.httpBody).flatMap {
            (try? JSONDecoder().decode(C64MachineInputEnvelope.self, from: $0).events) ?? []
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let isState = request.url?.path == "/v1/machine:input" && request.httpMethod == "GET"
        if isState { try await Task.sleep(for: stateDelay) }
        if request.httpMethod == "POST" { try await Task.sleep(for: postDelay) }
        let body = hasMouse
            ? "{\"mouse\":{\"attached\":false,\"inputs\":[],\"pending\":\(pending)},\"errors\":[]}"
            : #"{"errors":[]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class MouseInputTests: XCTestCase {
    private func info(_ version: String, product: String = "C64 Ultimate") throws -> UltimateAPIClient.DeviceInfo {
        let body = try JSONSerialization.data(withJSONObject: ["product": product, "firmware_version": version])
        return try JSONDecoder().decode(UltimateAPIClient.DeviceInfo.self, from: body)
    }

    private func controller(_ transport: MouseInputTransport) -> C64InputController {
        let controller = C64InputController(device: UltimateDevice(name: "Mouse", host: "192.0.2.1"), transport: transport)
        addTeardownBlock { @MainActor in
            await controller.cancelAndRelease()
            UserDefaults.standard.removeObject(forKey: "inputSettings.\(controller.settings.deviceID.uuidString)")
        }
        return controller
    }

    private func ready(_ controller: C64InputController) async throws {
        controller.setDeviceInfo(try info("1.2.1"))
        await controller.probeCapability()
        controller.settings.mouseEnabled = true
        XCTAssertTrue(controller.canCaptureMouse)
    }

    func testMouseRequiresCommodoreFinalFirmware121OrNewer() throws {
        for version in ["1.2.1", "1.2.2", "1.10.0", "2.0.0"] {
            XCTAssertTrue(try info(version).supportsRemoteMouseFirmware, version)
        }
        for version in ["1.1.0", "1.2.0", "1.2", "3.14", "1.2.1-rc1", "1.2.1 RC2", "garbage"] {
            XCTAssertFalse(try info(version).supportsRemoteMouseFirmware, version)
        }
        XCTAssertFalse(try info("3.15.0", product: "Ultimate 64-II").supportsRemoteMouseFirmware)
    }

    func testOldFirmwareNeverProbesOrSendsMouse() async throws {
        let transport = MouseInputTransport()
        let input = controller(transport)
        input.setDeviceInfo(try info("1.2.0"))
        await input.probeCapability()
        input.settings.mouseEnabled = true
        input.moveMouse(x: 10, y: 10)
        input.mouseButton("left", pressed: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(input.canCaptureMouse)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "GET" })
        let events = await transport.events
        XCTAssertFalse(events.contains { $0.kind == .mouse })
    }

    func testFirmwareGateAlsoRequiresMouseCapabilityAndMatrixTransport() async throws {
        let missing = controller(MouseInputTransport(hasMouse: false))
        missing.setDeviceInfo(try info("1.2.1"))
        await missing.probeCapability()
        missing.settings.mouseEnabled = true
        XCTAssertFalse(missing.canCaptureMouse)

        let supported = controller(MouseInputTransport())
        try await ready(supported)
        supported.settings.transport = .legacy
        XCTAssertFalse(supported.canCaptureMouse)
    }

    func testLateCapabilityResponseCannotEnableMouseAfterDisconnect() async throws {
        let input = controller(MouseInputTransport(stateDelay: .milliseconds(100)))
        input.setDeviceInfo(try info("1.2.1"))
        let probe = Task { await input.probeCapability() }
        try await Task.sleep(for: .milliseconds(20))
        input.invalidateMouseSupport()
        await probe.value
        XCTAssertFalse(input.settings.mouseAvailable)
    }

    func testMotionCoalescesFractionalDeltasAndPrecedesButtons() async throws {
        let transport = MouseInputTransport()
        let input = controller(transport)
        try await ready(input)
        for _ in 0..<100 { input.moveMouse(x: 0.25, y: -0.125) }
        input.mouseButton("left", pressed: true)
        input.mouseButton("left", pressed: false)
        try await Task.sleep(for: .milliseconds(60))
        let events = await transport.events.filter { $0.kind == .mouse }
        XCTAssertEqual(events, [
            .mouseMove(x: 25, y: -12),
            .mouseButton("left", transition: .press),
            .mouseButton("left", transition: .release)
        ])
        let requests = await transport.requests
        XCTAssertTrue(requests.compactMap(\.httpBody).allSatisfy { $0.count <= 4096 })
    }

    func testDisablingMouseDiscardsPendingMotionAndDetachesAfterInFlightInput() async throws {
        let transport = MouseInputTransport(postDelay: .milliseconds(40))
        let input = controller(transport)
        try await ready(input)
        input.mouseButton("right", pressed: true)
        try await Task.sleep(for: .milliseconds(5))
        input.moveMouse(x: 90, y: 90)
        input.settings.mouseEnabled = false
        try await Task.sleep(for: .milliseconds(160))
        let events = await transport.events
        XCTAssertEqual(events.last, .releaseAll)
        XCTAssertFalse(events.contains { $0.move != nil })
    }

    func testFocusCleanupReleasesMouseEvenWithNoKeyboardHeld() async throws {
        let transport = MouseInputTransport()
        let input = controller(transport)
        try await ready(input)
        input.moveMouse(x: 5, y: 0)
        try await Task.sleep(for: .milliseconds(40))
        input.releaseAllIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let events = await transport.events
        XCTAssertEqual(events.last, .releaseAll)
        let count = events.count
        input.releaseAllIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let after = await transport.events
        XCTAssertEqual(after.count, count)
    }

    func testScrollingUsesBoundedDetentsAndCorrectJSONFields() async throws {
        let transport = MouseInputTransport()
        let input = controller(transport)
        try await ready(input)
        input.scrollMouse(horizontal: 1, vertical: -1)
        try await Task.sleep(for: .milliseconds(50))
        let events = await transport.events
        let wheel = try XCTUnwrap(events.last?.wheel)
        XCTAssertEqual(wheel.horizontal, 1)
        XCTAssertEqual(wheel.vertical, -1)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(events.last!)) as! [String: Any]
        XCTAssertEqual(json["kind"] as? String, "mouse")
        XCTAssertNil(json["port"])
        XCTAssertNil(json["inputs"])
        XCTAssertNotNil(json["wheel"])
    }

    func testLegacySettingsDefaultMouseToOffWithoutLosingJoystickPreference() throws {
        let id = UUID()
        let key = "inputSettings.\(id.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(Data(#"{"transport":"Auto","keymap":"Symbolic","joystickEnabled":true,"joystickPort":1,"gameControllerEnabled":true,"deadzone":0.35}"#.utf8), forKey: key)
        let settings = InputSettings.shared(for: id)
        XCTAssertFalse(settings.mouseEnabled)
        XCTAssertFalse(settings.mouseAvailable)
        XCTAssertTrue(settings.joystickEnabled)
        XCTAssertEqual(settings.joystickPort, 1)
    }

    func testFirmwareBacklogDropsMotionButPreservesButtonRelease() async throws {
        let transport = MouseInputTransport(pending: 100)
        let input = controller(transport)
        try await ready(input)
        input.mouseButton("left", pressed: true)
        try await Task.sleep(for: .milliseconds(10))
        for _ in 0..<100 { input.moveMouse(x: 10, y: 10) }
        input.scrollMouse(horizontal: 2, vertical: 2)
        try await Task.sleep(for: .milliseconds(50))
        input.mouseButton("left", pressed: false)
        try await Task.sleep(for: .milliseconds(20))
        let events = await transport.events.filter { $0.kind == .mouse }
        XCTAssertEqual(events, [
            .mouseButton("left", transition: .press),
            .mouseButton("left", transition: .release)
        ])
    }
}
