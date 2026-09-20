import XCTest
@testable import Stream64

private actor BootingTransport: HTTPTransport {
    var infoRequests = 0
    var rebootRequests = 0
    var failuresLeft: Int
    var streamFailuresLeft: Int
    let dropRebootReply: Bool
    let rebootDelay: Duration
    init(failures: Int, dropRebootReply: Bool = false, streamFailures: Int = 0, rebootDelay: Duration = .zero) {
        failuresLeft = failures; self.dropRebootReply = dropRebootReply
        streamFailuresLeft = streamFailures
        self.rebootDelay = rebootDelay
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        if path == "/v1/machine:reboot" {
            rebootRequests += 1
            try await Task.sleep(for: rebootDelay)
            if dropRebootReply { throw URLError(.networkConnectionLost) }
        }
        if path == "/v1/streams/video:start", streamFailuresLeft > 0 {
            streamFailuresLeft -= 1
            throw URLError(.timedOut)
        }
        if path == "/v1/info" {
            infoRequests += 1
            if failuresLeft > 0 { failuresLeft -= 1; throw URLError(.cannotConnectToHost) }
        }
        let body = path == "/v1/info"
            ? #"{"product":"Ultimate 64-II","firmware_version":"3.15","errors":[]}"#
            : #"{"errors":[]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class ReconnectionTests: XCTestCase {
    private func device() -> UltimateDevice {
        var device = UltimateDevice.makeDefault()
        device.host = "127.0.0.1"
        device.videoPort = 24180; device.audioPort = 24181; device.debugPort = 24182
        return device
    }
    private func withSettings(_ body: (AppSettings) async throws -> Void) async rethrows {
        let settings = AppSettings()
        let auto = settings.reconnectAutomatically, audio = settings.audioEnabled, debug = settings.keepDebugStreamWarm
        settings.reconnectAutomatically = true; settings.audioEnabled = false; settings.keepDebugStreamWarm = false
        defer {
            settings.reconnectAutomatically = auto; settings.audioEnabled = audio; settings.keepDebugStreamWarm = debug
        }
        try await body(settings)
    }
    private func awaitConnection(_ session: DeviceSession) async throws {
        for _ in 0..<160 {
            if session.isConnected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Device never recovered: \(session.state)")
    }
    func testFailedStartupAutomaticallyConnectsWhenDeviceBecomesReady() async throws {
        try await withSettings { settings in
            let transport = BootingTransport(failures: 2)
            let session = DeviceSession(device: device(), settings: settings, transport: transport)
            defer { session.prepareForEviction() }
            await session.connect()
            XCTAssertEqual(session.state, .unreachable)
            XCTAssertTrue(session.isReconnecting)
            try await awaitConnection(session)
            XCTAssertFalse(session.isReconnecting)
            let requests = await transport.infoRequests
            XCTAssertGreaterThanOrEqual(requests, 3)
        }
    }
    func testManualConnectSupersedesPendingRetry() async throws {
        try await withSettings { settings in
            let transport = BootingTransport(failures: 2)
            let session = DeviceSession(device: device(), settings: settings, transport: transport)
            defer { session.prepareForEviction() }
            await session.connect()
            XCTAssertTrue(session.isReconnecting)
            await session.connect()
            XCTAssertTrue(session.isConnected)
            XCTAssertFalse(session.isReconnecting)
        }
    }
    func testRESTReadyBeforeStreamingRetriesCompleteConnection() async throws {
        try await withSettings { settings in
            let transport = BootingTransport(failures: 0, streamFailures: 1)
            let session = DeviceSession(device: device(), settings: settings, transport: transport)
            defer { session.prepareForEviction() }
            await session.connect()
            XCTAssertFalse(session.isConnected)
            XCTAssertTrue(session.isReconnecting)
            try await awaitConnection(session)
            XCTAssertFalse(session.isReconnecting)
        }
    }
    func testDisconnectCancelsPendingStartupRetries() async throws {
        try await withSettings { settings in
            let transport = BootingTransport(failures: 100)
            let session = DeviceSession(device: device(), settings: settings, transport: transport)
            await session.connect()
            XCTAssertTrue(session.isReconnecting)
            await session.disconnect(stopRemoteStreams: false)
            let before = await transport.infoRequests
            try await Task.sleep(for: .milliseconds(2400))
            let after = await transport.infoRequests
            XCTAssertEqual(before, after)
            XCTAssertEqual(session.state, .disconnected)
            XCTAssertFalse(session.isReconnecting)
        }
    }
    func testDisablingAutomaticReconnectionStopsPendingRetry() async throws {
        try await withSettings { settings in
            let transport = BootingTransport(failures: 100)
            let session = DeviceSession(device: device(), settings: settings, transport: transport)
            defer { session.prepareForEviction() }
            await session.connect()
            settings.reconnectAutomatically = false
            try await Task.sleep(for: .milliseconds(2400))
            let requests = await transport.infoRequests
            XCTAssertEqual(requests, 2)
            XCTAssertFalse(session.isReconnecting)
        }
    }
    func testDisconnectWhileRebootReplyIsPendingDoesNotReconnect() async throws {
        try await withSettings { settings in
            let transport = BootingTransport(failures: 0, rebootDelay: .milliseconds(500))
            let session = DeviceSession(device: device(), settings: settings, transport: transport)
            defer { session.prepareForEviction() }
            let reboot = Task { await session.rebootAndReconnect() }
            for _ in 0..<100 {
                if await transport.rebootRequests > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await session.disconnect(stopRemoteStreams: false)
            await reboot.value
            XCTAssertEqual(session.state, .disconnected)
            XCTAssertFalse(session.isReconnecting)
            let probes = await transport.infoRequests
            XCTAssertEqual(probes, 0)
        }
    }
    func testRebootWithLostHTTPReplyWaitsForFullConnection() async throws {
        try await withSettings { settings in
            settings.reconnectAutomatically = false
            let transport = BootingTransport(failures: 2, dropRebootReply: true)
            let session = DeviceSession(device: device(), settings: settings, transport: transport)
            defer { session.prepareForEviction() }
            await session.rebootAndReconnect()
            XCTAssertTrue(session.isReconnecting)
            try await awaitConnection(session)
            let reboots = await transport.rebootRequests
            XCTAssertEqual(reboots, 1)
            XCTAssertFalse(session.isReconnecting)
        }
    }
}
