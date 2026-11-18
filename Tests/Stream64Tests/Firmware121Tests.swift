import XCTest
import SwiftUI
import ZIPFoundation
import Darwin
@testable import Stream64

actor Firmware121Transport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    var values = ["Audio Mixer": ["Vol Master": " 0 dB", "Vol Socket 1": " 0 dB"],
                  "U64 Specific Settings": ["Mouse Sensitivity": "8", "Mouse Mode": "Mouse", "Wake On Wi-Fi": "Disabled"],
                  "SoftIEC Drive Settings": ["IEC Drive": "UCI Only", "Soft Drive Bus ID": "11", "Log Every Operation": "Disabled"]]
    var failKey: String?
    var failOnce = true
    var ignoreWrites = false
    init(failKey: String? = nil, ignoreWrites: Bool = false) { self.failKey = failKey; self.ignoreWrites = ignoreWrites }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        let parts = path.split(separator: "/").map(String.init)
        var result: [String: Any] = ["errors": [String]()]
        if path == "/v1/drives" {
            result["drives"] = [
                ["a": ["enabled": true, "bus_id": 8, "type": "1541", "image_file": "game.d64", "image_path": "/Usb0/Games"]],
                ["IEC Drive": ["enabled": false, "bus_id": 11, "type": "DOS emulation", "last_error": "73,READY,00,00", "partitions": [["id": 1, "path": "/Temp/"]]]],
                ["Printer Emulation": ["enabled": false, "bus_id": 4]]
            ]
        } else if path == "/v1/configs" {
            result["categories"] = values.keys.sorted()
        } else if parts.count >= 3, parts[1] == "configs", let group = values[parts[2]] {
            if request.httpMethod == "PUT", parts.count == 4 {
                if parts[3] == failKey && failOnce {
                    failOnce = false
                    throw URLError(.networkConnectionLost)
                }
                let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "value" }?.value
                if !ignoreWrites { values[parts[2]]?[parts[3]] = value }
            } else if parts.count == 4 && parts[3] == "*" {
                result[parts[2]] = group.mapValues { value -> [String: Any] in
                    if let number = Int(value) { return ["current": number, "min": 1, "max": 30] }
                    return ["current": value, "values": [" 0 dB", "-6 dB", "Mouse", "Cursor", "UCI Only", "Enabled", "Disabled"]]
                }
            } else { result[parts[2]] = group }
        }
        let data = path == "/v1/machine:readmem" ? Data([0]) : try JSONSerialization.data(withJSONObject: result)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class Firmware121Tests: XCTestCase {
    private func api(_ transport: Firmware121Transport = Firmware121Transport()) -> UltimateAPIClient {
        .init(device: UltimateDevice(name: "Fixture C64", host: "192.0.2.1"), transport: transport)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream64-fw-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func p00(_ prg: Data = Data([1, 8, 0, 0])) -> Data {
        var header = Data("C64File\0".utf8)
        header.append(Data("EMBEDDED NAME".utf8))
        header.append(Data(repeating: 0, count: 26 - header.count))
        return header + prg
    }
    private func reference(_ url: URL) -> TransferReference {
        .init(endpoint: .local, path: ManagedPath(url.path), isDirectory: false, size: nil)
    }

    func testDriveParserKeepsSoftIECDiagnosticsPartitionsAndMountedPath() async throws {
        let drives = try await api().fetchDrives()
        XCTAssertEqual(drives.count, 3)
        let soft = try XCTUnwrap(drives.first { $0.isSoftIEC })
        XCTAssertEqual(soft.letter, "softiec")
        XCTAssertEqual(soft.busID, 11)
        XCTAssertEqual(soft.partitions, [.init(id: 1, path: "/Temp/")])
        XCTAssertEqual(soft.lastError, "73,READY,00,00")
        XCTAssertEqual(drives.first { $0.letter == "a" }?.mountedImagePath, "/Usb0/Games/game.d64")
        XCTAssertFalse(drives.first { $0.letter == "printer emulation" }!.isEmulated)
    }

    func testSoftIECPowerResetAndDNPRequestsUseInstalledAPI() async throws {
        let transport = Firmware121Transport(), client = api(transport)
        try await client.turnDriveOn(drive: "softiec")
        try await client.turnDriveOff(drive: "softiec")
        try await client.resetDrive(drive: "softiec")
        try await client.createBlankDisk(path: "/Temp/test.dnp", kind: .dnp, tracks: 17, diskName: "TEST")
        let requests = await transport.requests
        XCTAssertEqual(requests.prefix(3).compactMap { $0.url?.path }, ["/v1/drives/softiec:on", "/v1/drives/softiec:off", "/v1/drives/softiec:reset"])
        let last = try XCTUnwrap(requests.last?.url)
        XCTAssertEqual(last.path, "/v1/files/Temp/test.dnp:create_dnp")
        XCTAssertTrue(last.query!.contains("tracks=17"))
        do { try await client.createBlankDisk(path: "/Temp/bad.dnp", kind: .dnp, tracks: 256); XCTFail("Accepted oversized DNP") } catch {}
        let count = await transport.requests.count
        XCTAssertEqual(count, 4)
    }

    func testConfigMetadataPreservesNumericCurrentValuesAndOptions() async throws {
        let items = try await api().fetchConfigItems(category: "U64 Specific Settings")
        let sensitivity = try XCTUnwrap(items.first { $0.key == "Mouse Sensitivity" })
        XCTAssertEqual(sensitivity.value, "8")
        XCTAssertEqual(sensitivity.minimum, 1)
        XCTAssertEqual(sensitivity.maximum, 30)
        XCTAssertTrue(items.first { $0.key == "Mouse Mode" }!.options.contains("Cursor"))
    }

    func testDeviceSettingsApplyReadBackAndDoNotSaveToFlashImplicitly() async throws {
        let transport = Firmware121Transport()
        let model = FirmwareSettingsModel(api: api(transport), category: "U64 Specific Settings")
        await model.load()
        model.drafts["Mouse Sensitivity"] = "12"
        await model.apply("Mouse Sensitivity")
        XCTAssertEqual(model.items.first { $0.key == "Mouse Sensitivity" }?.value, "12")
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url!.path.contains("save_to_flash") })
        model.drafts["Mouse Sensitivity"] = "999"
        await model.apply("Mouse Sensitivity")
        XCTAssertTrue(model.status?.contains("1 to 30") == true)
        let after = await transport.requests.count
        XCTAssertEqual(after, requests.count)
    }

    func testDeviceSettingsDetectAcknowledgedButUnappliedWrite() async throws {
        let model = FirmwareSettingsModel(api: api(Firmware121Transport(ignoreWrites: true)), category: "Audio Mixer")
        await model.load(); model.drafts["Vol Master"] = "-6 dB"
        await model.apply("Vol Master")
        XCTAssertTrue(model.status?.contains("did not retain") == true)
    }

    func testP00HeaderAndPayloadValidation() throws {
        let file = try PC64File(data: p00(), filename: "outer.P00")
        XCTAssertEqual(file.name, "EMBEDDED NAME")
        XCTAssertEqual(try file.programData(), Data([1, 8, 0, 0]))
        XCTAssertThrowsError(try PC64File(data: Data([1, 8]), filename: "bad.p00"))
        var bad = p00(); bad[25] = 1
        XCTAssertThrowsError(try PC64File(data: bad, filename: "bad.p00"))
        XCTAssertThrowsError(try PC64File(data: p00(), filename: "seq.s00").programData())
        XCTAssertEqual(ManagedFileKind.classify(name: "demo.P00", isDirectory: false), .prg)
        XCTAssertTrue(ViewerPane.isDroppableURL(URL(fileURLWithPath: "/tmp/demo.P00")))
    }

    func testP00UploadStripsWrapperAndDisplaysEmbeddedName() async throws {
        let transport = Firmware121Transport()
        let session = DeviceSession(device: UltimateDevice(name: "Fixture", host: "192.0.2.1"), settings: AppSettings(), transport: transport)
        defer { session.prepareForEviction() }
        let result = await session.loadData(p00(), filename: "wrapped.p00")
        XCTAssertEqual(result, .running("wrapped.p00"))
        let requests = await transport.requests
        XCTAssertEqual(requests.last { $0.url?.path == "/v1/runners:run_prg" }?.httpBody, Data([1, 8, 0, 0]))
        XCTAssertEqual(session.transferStatus, .done("Running EMBEDDED NAME"))
    }

    func testMalformedP00NeverUploadsOrAppliesTitleSettings() async throws {
        let transport = Firmware121Transport()
        let session = DeviceSession(device: UltimateDevice(name: "Fixture", host: "192.0.2.1"), settings: AppSettings(), transport: transport)
        defer { session.prepareForEviction() }
        let result = await session.loadData(Data([1, 8]), filename: "bad.p00", titleProfile: .init(values: ["Audio Mixer": ["Vol Master": "-6 dB"]]))
        XCTAssertNil(result)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testArchivePicksMatchingSiblingProfileAndP00Payload() throws {
        let data = try makeArchive([
            ("dir/game.p00", p00(), .file, .deflate), ("dir/game.cfg", Data("[Audio Mixer]\nVol Master=-6 dB\n".utf8), .file, .deflate),
            ("other/game.cfg", Data("invalid settings".utf8), .file, .deflate)
        ])
        let payload = try Assembly64ArchiveInspector.firstSupportedPayload(from: data)
        XCTAssertEqual(payload.filename, "game.p00")
        XCTAssertEqual(payload.titleProfile?.values["Audio Mixer"]?["Vol Master"], "-6 dB")
    }

    func testTitleSettingsParseRoundTripRejectsDuplicatesAndInjection() throws {
        let input = Data("; header\r\n[Audio Mixer]\r\nVol Master= -6 dB \r\n[U64 Specific Settings]\nMouse Sensitivity=12\n".utf8)
        let profile = try TitleSettingsProfile(data: input)
        XCTAssertEqual(try TitleSettingsProfile(data: profile.data), profile)
        XCTAssertEqual(TitleSettingsProfile.companionPath(for: ManagedPath("/Temp/a.b.p00")).rawValue, "/Temp/a.b.cfg")
        for invalid in ["x=1", "[A]\nx=1\nx=2", "[A]\n\0bad=1", "[A]\n" + String(repeating: "X", count: 321)] {
            XCTAssertThrowsError(try TitleSettingsProfile(data: Data(invalid.utf8)))
        }
    }

    func testTitleSettingsPrevalidateAllBeforeMutationAndRollBackFailedBatch() async throws {
        let transport = Firmware121Transport(failKey: "Mouse Sensitivity")
        let client = api(transport)
        let invalid = TitleSettingsProfile(values: ["Audio Mixer": ["Vol Master": "-6 dB"], "U64 Specific Settings": ["Mouse Sensitivity": "999"]])
        do { try await TitleSettingsService.apply(invalid, api: client); XCTFail("Accepted invalid profile") } catch {}
        let before = await transport.requests
        XCTAssertFalse(before.contains { $0.httpMethod == "PUT" })
        let valid = TitleSettingsProfile(values: ["Audio Mixer": ["Vol Master": "-6 dB"], "U64 Specific Settings": ["Mouse Sensitivity": "12"]])
        do { try await TitleSettingsService.apply(valid, api: client); XCTFail("Ignored write failure") } catch {}
        let state = await transport.values
        XCTAssertEqual(state["Audio Mixer"]?["Vol Master"], " 0 dB")
        XCTAssertEqual(state["U64 Specific Settings"]?["Mouse Sensitivity"], "8")
    }

    func testTitleSettingsApplyBeforeRunnerAndAbortIfInvalid() async throws {
        let transport = Firmware121Transport()
        let session = DeviceSession(device: UltimateDevice(name: "Fixture", host: "192.0.2.1"), settings: AppSettings(), transport: transport)
        defer { session.prepareForEviction() }
        let profile = TitleSettingsProfile(values: ["Audio Mixer": ["Vol Master": "-6 dB"]])
        _ = await session.loadData(Data([1, 8, 0, 0]), filename: "game.prg", titleProfile: profile)
        let requests = await transport.requests
        let config = try XCTUnwrap(requests.firstIndex { $0.httpMethod == "PUT" && $0.url!.path.contains("Vol Master") })
        let runner = try XCTUnwrap(requests.firstIndex { $0.url!.path == "/v1/runners:run_prg" })
        XCTAssertLessThan(config, runner)
    }

    func testProfileEditorFileStoreRoundTripAndCopyMoveCompanions() async throws {
        let dir = try directory(), source = dir.appendingPathComponent("game.prg"), copy = dir.appendingPathComponent("copy.prg"), moved = dir.appendingPathComponent("moved.prg")
        try Data([1, 8, 0, 0]).write(to: source)
        let item = FilesystemItem(endpoint: .local, path: ManagedPath(source.path), kind: .prg, size: 4, modified: nil)
        let profile = TitleSettingsProfile(values: ["Audio Mixer": ["Vol Master": "-6 dB"]])
        let store = TitleProfileFileStore(devices: [])
        try await store.save(profile, for: item)
        let loaded = try await store.load(for: item)
        XCTAssertEqual(loaded, profile)
        let coordinator = FileOperationCoordinator(deviceResolver: { _ in nil })
        try await coordinator.process(.init(operation: .copy(source: reference(source), destination: reference(copy)), includesTitleSettings: true)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: copy.deletingPathExtension().appendingPathExtension("cfg")), profile.data)
        try await coordinator.process(.init(operation: .move(source: reference(source), destination: reference(moved)), includesTitleSettings: true)) { _, _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.deletingPathExtension().appendingPathExtension("cfg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.deletingPathExtension().appendingPathExtension("cfg").path))
    }

    func testMoveWithSkippedSettingsKeepsSourceTitleAndSettings() async throws {
        let dir = try directory(), source = dir.appendingPathComponent("game.prg"), target = dir.appendingPathComponent("target.prg")
        try Data([1, 8]).write(to: source)
        try Data("original".utf8).write(to: source.deletingPathExtension().appendingPathExtension("cfg"))
        try Data("existing".utf8).write(to: target.deletingPathExtension().appendingPathExtension("cfg"))
        let coordinator = FileOperationCoordinator(deviceResolver: { _ in nil })
        try await coordinator.process(.init(operation: .move(source: reference(source), destination: reference(target)), conflictPolicy: .skip, includesTitleSettings: true)) { _, _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.deletingPathExtension().appendingPathExtension("cfg").path))
    }

    func testMountedImageGuardBlocksImageChildrenAndParentRemovalButAllowsOtherFiles() async throws {
        let drives = try await api().fetchDrives()
        for path in ["/Usb0/Games/game.d64", "/Usb0/Games/game.d64/NEW.PRG", "/Usb0/Games"] {
            XCTAssertThrowsError(try MountedImageProtection.validateMutation(ManagedPath(path), drives: drives), path)
        }
        XCTAssertNoThrow(try MountedImageProtection.validateMutation(ManagedPath("/Usb0/Games/other.d64"), drives: drives))
        let id = UUID(), device = UltimateDevice(id: id, name: "Fixture", host: "192.0.2.1")
        let coordinator = FileOperationCoordinator(deviceResolver: { _ in device }, inspectDrives: { _ in drives })
        let ref = TransferReference(endpoint: .ultimate(id), path: ManagedPath("/Usb0/Games/game.d64/NEW.PRG"), isDirectory: false, size: nil)
        do { try await coordinator.process(.init(operation: .delete(target: ref))) { _, _ in }; XCTFail("Allowed mounted mutation") } catch {}
    }

    func testMountedProtectionFailsClosedWhenSnapshotCannotBeRead() async throws {
        let device = UltimateDevice(name: "Fixture", host: "192.0.2.1")
        let coordinator = FileOperationCoordinator(deviceResolver: { _ in device }, inspectDrives: { _ in throw URLError(.timedOut) })
        let ref = TransferReference(endpoint: .ultimate(device.id), path: ManagedPath("/Temp/file.prg"), isDirectory: false, size: nil)
        do { try await coordinator.process(.init(operation: .delete(target: ref))) { _, _ in }; XCTFail("Allowed unknown drive state") }
        catch { XCTAssertTrue(error is URLError) }
    }

    func testExtraFireKeysAndGamepadMappingsPreserveOrderedPressRelease() async throws {
        let transport = Firmware121Transport()
        let input = C64InputController(device: UltimateDevice(name: "Fixture", host: "192.0.2.1"), transport: transport)
        let settings = input.settings
        settings.transport = .matrix; settings.joystickEnabled = true; settings.joystickPort = 2
        settings.fire2Key = .z; settings.fire3Key = .x; settings.buttonB = .fire2
        XCTAssertEqual(C64HostKeyMapper.action(for: .init(keyCode: 6, characters: "z", modifiers: [], isRepeat: false), settings: settings), .joystick(.fire2))
        XCTAssertEqual(C64HostKeyMapper.action(for: .init(keyCode: 7, characters: "x", modifiers: [], isRepeat: false), settings: settings), .joystick(.fire3))
        let gamepads = GameControllerManager.shared
        gamepads.setTarget(input); gamepads.setButton("B", pressed: true); gamepads.setButton("B", pressed: false)
        try await Task.sleep(for: .milliseconds(40))
        let requests = await transport.requests
        let events = requests.compactMap(\.httpBody).flatMap { (try? JSONDecoder().decode(C64MachineInputEnvelope.self, from: $0).events) ?? [] }
        XCTAssertTrue(events.contains(.joystick("fire2", port: 2, transition: .press)))
        XCTAssertTrue(events.contains(.joystick("fire2", port: 2, transition: .release)))
        gamepads.setTarget(nil)
        await input.cancelAndRelease()
        UserDefaults.standard.removeObject(forKey: "inputSettings.\(settings.deviceID.uuidString)")
    }

    func testWakePacketAndActualUDPSend() throws {
        let packet = try WakeOnLANService.packet(mac: "F0:9E:9E:74:39:08")
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(packet.prefix(6), Data(repeating: 255, count: 6))
        XCTAssertEqual(packet.suffix(6), Data([0xF0, 0x9E, 0x9E, 0x74, 0x39, 0x08]))
        for invalid in ["bad", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "F0:9E:9E:74:39:GG"] { XCTAssertThrowsError(try WakeOnLANService.packet(mac: invalid)) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try WakeOnLANService.send(mac: "F0:9E:9E:74:39:08", address: "127.0.0.1", port: UInt16(bigEndian: address.sin_port))
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = recv(fd, &bytes, bytes.count, 0)
        XCTAssertEqual(Data(bytes.prefix(max(0, count))), packet)
    }

    func testLearnedWiFiIdentitySurvivesOfflineSessionAndNeverUsesEthernetMAC() throws {
        let id = UUID(); defer { UserDefaults.standard.removeObject(forKey: "wifiMAC.\(id.uuidString)") }
        let info = try JSONDecoder().decode(UltimateAPIClient.DeviceInfo.self, from: Data(#"{"product":"C64 Ultimate","firmware_version":"1.2.1","wifi_mac":"F0:9E:9E:74:39:08","ethernet_mac":"02:15:41:41:7C:27"}"#.utf8))
        DeviceNetworkIdentity.remember(info, for: id)
        XCTAssertEqual(DeviceNetworkIdentity.wifiMAC(for: id), "F0:9E:9E:74:39:08")
        let session = DeviceSession(device: UltimateDevice(id: id, name: "Fixture", host: "192.0.2.1"), settings: AppSettings(), transport: Firmware121Transport())
        defer { session.prepareForEviction() }
        XCTAssertTrue(session.canWake)
    }

    func testFirmwareMenuSelectionRequiresExactHighlightedText() {
        let screen = VT100Screen(columns: 60, rows: 25)
        screen.feed(Data("\u{1B}[5;5H\u{1B}[0;31;2mSave Debug Log\u{1B}[6;5H\u{1B}[0;37;1mSave Cartridge".utf8))
        XCTAssertTrue(FirmwareMenuSelection.contains("Save Debug Log", in: screen))
        XCTAssertFalse(FirmwareMenuSelection.contains("Save Debug Log", in: screen, selected: true))
        XCTAssertTrue(FirmwareMenuSelection.contains("Save Cartridge", in: screen, selected: true))
        XCTAssertEqual(FirmwareMenuAction.saveDebugLog.categories, ["Developer"])
    }
}
