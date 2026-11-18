import XCTest
@testable import Stream64

@MainActor
final class Firmware121LiveTests: XCTestCase {
    private func device() throws -> UltimateDevice {
        guard let host = ProcessInfo.processInfo.environment["UV_LIVE_FIRMWARE_HOST"] else {
            throw XCTSkip("Set UV_LIVE_FIRMWARE_HOST for live C64 firmware validation")
        }
        return UltimateDevice(name: "Firmware acceptance C64", host: host)
    }

    func testLiveSettingsSoftIECFilesDNPProtectionProfilesP00AndExtraFire() async throws {
        let device = try device(), api = UltimateAPIClient(device: device, timeout: 30)
        let info = try await api.fetchInfo()
        XCTAssertTrue(info.supportsRemoteMouseFirmware)
        XCTAssertNotNil(info.wifiMAC)
        let baseline = try await api.fetchDrives()
        XCTAssertNotNil(baseline.first { $0.isSoftIEC })
        let drive = try XCTUnwrap(baseline.first { $0.isEmulated && $0.imageFile == nil })
        let savedAudio = try await api.fetchConfigItems(category: "Audio Mixer")
        let savedHardware = try await api.fetchConfigItems(category: "U64 Specific Settings")
        let savedIEC = try await api.fetchConfigItems(category: "SoftIEC Drive Settings")
        let id = "s64fw-" + String(UUID().uuidString.prefix(8)).lowercased()
        let root = ManagedPath("/Temp/" + id)
        let ftp = UltimateFTPClient(device: device, timeout: 30)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try await ftp.makeDirectory(root)
        addTeardownBlock {
            try? await api.releaseAllInput()
            try? await api.unmountDisk(drive: drive.letter)
            for (category, items, keys) in [
                ("Audio Mixer", savedAudio, ["Vol Master", "Vol Socket 1"]),
                ("U64 Specific Settings", savedHardware, ["Mouse Mode", "Mouse Sensitivity", "Mouse Acceleration", "Mouse Wheel Sensitivity", "Mouse Wheel Direction", "Menu Mouse Navigation"]),
                ("SoftIEC Drive Settings", savedIEC, ["IEC Drive", "Log Every Operation"])
            ] {
                for item in items where keys.contains(item.key) {
                    try await api.setConfigItem(category: category, item: item.key, value: item.value)
                    let after = try await api.fetchConfigItems(category: category)
                    XCTAssertEqual(after.first { $0.key == item.key }?.value, item.value, "Restore \(item.key)")
                }
            }
            let provider = UltimateFileSystemProvider(device: device)
            try await provider.delete(root, recursive: true)
            let removed = try await ftp.stat(root)
            XCTAssertNil(removed)
            try? FileManager.default.removeItem(at: local)
        }

        // Exercise the exact settings model used by mixer/mouse/SoftIEC UI.
        for (category, key) in [("Audio Mixer", "Vol Master"), ("U64 Specific Settings", "Mouse Sensitivity"), ("SoftIEC Drive Settings", "Log Every Operation")] {
            let model = FirmwareSettingsModel(api: api, category: category)
            await model.load()
            let item = try XCTUnwrap(model.items.first { $0.key == key })
            let alternate = item.options.first { $0 != item.value } ?? String((Int(item.value) ?? 8) == 8 ? 9 : 8)
            model.drafts[key] = alternate; await model.apply(key)
            XCTAssertEqual(model.items.first { $0.key == key }?.value, alternate, model.status ?? "")
            model.drafts[key] = item.value; await model.apply(key)
            XCTAssertEqual(model.items.first { $0.key == key }?.value, item.value)
        }
        try await api.turnDriveOn(drive: "softiec")
        var drives = try await api.fetchDrives()
        XCTAssertTrue(drives.first { $0.isSoftIEC }!.enabled)
        try await api.resetDrive(drive: "softiec")
        try await api.turnDriveOff(drive: "softiec")
        drives = try await api.fetchDrives()
        XCTAssertFalse(drives.first { $0.isSoftIEC }!.enabled)
        let originalMode = try XCTUnwrap(savedIEC.first { $0.key == "IEC Drive" }?.value)
        try await api.setConfigItem(category: "SoftIEC Drive Settings", item: "IEC Drive", value: originalMode)

        let dnp = root.appending("native.dnp")
        try await api.createBlankDisk(path: dnp.rawValue, kind: .dnp, tracks: 2, diskName: "STREAM64 TEST")
        let dnpItem = try await ftp.stat(dnp)
        XCTAssertEqual(dnpItem?.size, 2 * 65536)
        let disk = root.appending("mounted.d64")
        try await api.createBlankDisk(path: disk.rawValue, kind: .d64, tracks: 35, diskName: "STREAM64 TEST")
        try await api.mountDisk(path: disk.rawValue, drive: drive.letter, mode: "readonly")
        drives = try await api.fetchDrives()
        XCTAssertEqual(drives.first { $0.letter == drive.letter }?.mountedImagePath, disk.rawValue)
        let coordinator = FileOperationCoordinator(deviceResolver: { _ in device })
        let blocked = TransferReference(endpoint: .ultimate(device.id), path: disk, isDirectory: false, size: nil)
        do { try await coordinator.process(.init(operation: .delete(target: blocked))) { _, _ in }; XCTFail("Mounted image deletion was allowed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("mounted")) }
        let intact = try await ftp.stat(disk)
        XCTAssertNotNil(intact)
        try await api.unmountDisk(drive: drive.letter)

        // Create a harmless BASIC REM program. The native and P00 runners can
        // be checked by reading the loaded program back, rather than trusting 200.
        let message = Array(" STREAM64 FIRMWARE TEST".utf8)
        let next = 0x0801 + 5 + message.count + 1
        let body = Data([UInt8(next & 255), UInt8(next >> 8), 10, 0, 0x8F] + message + [0, 0, 0])
        let prg = Data([1, 8]) + body
        var wrapped = Data("C64File\0STREAM64 TEST".utf8)
        wrapped.append(Data(repeating: 0, count: 26 - wrapped.count)); wrapped.append(prg)
        let program = local.appendingPathComponent("acceptance.p00")
        try wrapped.write(to: program)
        let profile = TitleSettingsProfile(values: ["U64 Specific Settings": ["Mouse Sensitivity": "10"]])
        try profile.data.write(to: program.deletingPathExtension().appendingPathExtension("cfg"))
        let remote = root.appending("acceptance.p00")
        try await coordinator.process(.init(operation: .copy(
            source: .init(endpoint: .local, path: ManagedPath(program.path), isDirectory: false, size: Int64(wrapped.count)),
            destination: .init(endpoint: .ultimate(device.id), path: remote, isDirectory: false, size: nil)), includesTitleSettings: true)) { _, _ in }
        let item = FilesystemItem(endpoint: .ultimate(device.id), path: remote, kind: .prg, size: Int64(wrapped.count), modified: nil)
        let fileStore = TitleProfileFileStore(devices: [device])
        let loaded = try await fileStore.load(for: item)
        XCTAssertEqual(loaded, profile)
        try await fileStore.save(.init(values: ["U64 Specific Settings": ["Mouse Sensitivity": "11"]]), for: item)
        let edited = try await fileStore.load(for: item)
        XCTAssertEqual(edited?.values["U64 Specific Settings"]?["Mouse Sensitivity"], "11")
        let session = DeviceSession(device: device, settings: AppSettings())
        defer { session.prepareForEviction() }
        _ = await session.loadData(wrapped, filename: "acceptance.p00", titleProfile: profile)
        XCTAssertEqual(session.transferStatus, .done("Running STREAM64 TEST"))
        try await Task.sleep(for: .milliseconds(300))
        let uploadedMemory = try await api.readMemory(address: 0x0801, length: body.count)
        XCTAssertEqual(uploadedMemory, body)
        // PUT runner must honour the edited sibling cfg on real firmware too.
        await session.loadRemoteFile(path: remote.rawValue, filename: remote.name, titleProfile: edited)
        let configured = try await api.fetchConfigItems(category: "U64 Specific Settings")
        XCTAssertEqual(configured.first { $0.key == "Mouse Sensitivity" }?.value, "11")
        let remoteMemory = try await api.readMemory(address: 0x0801, length: body.count)
        XCTAssertEqual(remoteMemory, body)

        try await api.sendMachineInput([
            .mouseMove(x: 12, y: -7), .mouseWheel(vertical: 1, horizontal: -1),
            .mouseButton("left", transition: .press), .mouseButton("middle", transition: .press),
            .mouseButton("right", transition: .press)
        ])
        var mouse = try await api.fetchMachineInputState()
        for _ in 0..<40 where mouse.mouse?.pending != 0 {
            try await Task.sleep(for: .milliseconds(50))
            mouse = try await api.fetchMachineInputState()
        }
        XCTAssertEqual(mouse.mouse?.pending, 0)
        XCTAssertEqual(mouse.mouse?.attached, true)
        XCTAssertEqual(Set(mouse.mouse?.inputs ?? []), Set(["left", "middle", "right"]))
        try await api.sendMachineInput([.joystick("fire2", port: 2, transition: .press), .joystick("fire3", port: 2, transition: .press)])
        let input = try await api.fetchMachineInputState()
        XCTAssertEqual(Set(input.joysticks?.first { $0.port == 2 }?.inputs ?? []), Set(["fire2", "fire3"]))
        try await api.releaseAllInput()
        let released = try await api.fetchMachineInputState()
        XCTAssertTrue(released.joysticks?.allSatisfy { $0.inputs.isEmpty } == true)
        XCTAssertFalse(released.mouse?.attached ?? true)
    }

    func testLiveFirmwareDebugLogMenuExportAndRetrieval() async throws {
        let device = try device()
        let session = DeviceSession(device: device, settings: AppSettings())
        let model = TelnetMonitorViewModel(session: session)
        let filename = "s64log" + String(UUID().uuidString.prefix(6)).lowercased() + ".log"
        let path = ManagedPath("/Temp/" + filename)
        let ftp = UltimateFTPClient(device: device, timeout: 30)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        addTeardownBlock { @MainActor in
            model.stop(); session.prepareForEviction()
            if try await ftp.stat(path) != nil { try await ftp.deleteFile(path) }
            try? FileManager.default.removeItem(at: local)
        }
        model.start()
        try await enterTemp(model)
        model.perform(.saveDebugLog)
        try await wait { model.status.contains("Enter a filename") || model.status.contains("unavailable") }
        if model.status.contains("unavailable") {
            let text = (0..<model.screen.rows).map { row in String((0..<model.screen.columns).map { model.screen.cell(atColumn: $0, row: row).character }) }.joined(separator: "\n")
            try text.write(toFile: "/tmp/stream64-menu-failure.txt", atomically: true, encoding: .utf8)
            let styled = model.screen.cells.map { "\($0.character):\($0.foreground):\($0.bold)" }.joined(separator: " ")
            try styled.write(toFile: "/tmp/stream64-menu-failure-styles.txt", atomically: true, encoding: .utf8)
        }
        XCTAssertFalse(model.status.contains("unavailable"), model.status)
        try await wait { FirmwareMenuSelection.contains("filename", in: model.screen) }
        model.send(Data((filename + "\r").utf8))
        try await Task.sleep(for: .milliseconds(500))
        let saved = try await ftp.stat(path)
        XCTAssertGreaterThan(saved?.size ?? 0, 0)
        try await ftp.download(path, to: local) { _, _ in }
        XCTAssertGreaterThan(try Data(contentsOf: local).count, 0)
    }

    func testLiveTapeControlsAndCartridgeSave() async throws {
        let device = try device(), api = UltimateAPIClient(device: device, timeout: 30)
        let ftp = UltimateFTPClient(device: device, timeout: 30)
        let name = "s64media" + String(UUID().uuidString.prefix(5)).lowercased()
        let tapePath = ManagedPath("/Temp/" + name + ".tap")
        let cartPath = ManagedPath("/Temp/" + name + ".crt")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        var tape = Data("C64-TAPE-RAW".utf8)
        tape.append(contentsOf: [1, 0, 0, 0])
        let pulses = 100000
        tape.append(contentsOf: (0..<4).map { UInt8((pulses >> ($0 * 8)) & 255) })
        tape.append(Data(repeating: 255, count: pulses))
        try tape.write(to: local)
        try await ftp.upload(local, to: tapePath) { _, _ in }
        let session = DeviceSession(device: device, settings: AppSettings())
        let model = TelnetMonitorViewModel(session: session)
        addTeardownBlock { @MainActor in
            model.stop(); session.prepareForEviction()
            try? await api.runPRG(data: Data([1,8,0,0]))
            for path in [tapePath, cartPath] { if try await ftp.stat(path) != nil { try await ftp.deleteFile(path) } }
            try? FileManager.default.removeItem(at: local)
        }
        model.start()
        try await enterTemp(model)
        try await model.selectMenuLabel(name + ".tap")
        model.perform(.startTape)
        try await wait { !model.actionBusy && model.status.contains("Requested Start Tape") || model.status.contains("unavailable") }
        if model.status.contains("unavailable") { try dump(model, name: "tape") }
        XCTAssertEqual(model.status, "Requested Start Tape.")
        guard !model.status.contains("unavailable") else { return }
        for action in [FirmwareMenuAction.pauseTape, .resumeTape, .stopTape] {
            model.perform(action)
            try await wait { !model.actionBusy && (model.status == "Requested \(action.rawValue)." || model.status.contains("unavailable")) }
            XCTAssertEqual(model.status, "Requested \(action.rawValue).")
        }
        // Minimal EasyFlash cartridge: a harmless infinite loop in bank zero.
        var crt = Data(repeating: 0, count: 64)
        crt.replaceSubrange(0..<16, with: Data("C64 CARTRIDGE   ".utf8))
        crt[0x13] = 0x40; crt[0x14] = 1; crt[0x17] = 32; crt[0x18] = 0; crt[0x19] = 1
        for address in [UInt16(0x8000), UInt16(0xA000)] {
            var chip = Data("CHIP".utf8)
            chip.append(contentsOf: [0,0,0x20,0x10,0,2,0,0,UInt8(address >> 8),0,0x20,0])
            var rom = Data(repeating: 0xFF, count: 8192)
            if address == 0x8000 { rom.replaceSubrange(0..<12, with: [0x09,0x80,0x09,0x80,0xC3,0xC2,0xCD,0x38,0x30,0x4C,0x09,0x80]) }
            chip.append(rom); crt.append(chip)
        }
        try await api.runCRT(data: crt)
        try await Task.sleep(for: .milliseconds(300))
        model.perform(.saveCartridge)
        try await wait { !model.actionBusy && (model.status.contains("Enter a filename") || model.status.contains("unavailable")) }
        if model.status.contains("unavailable") { try dump(model, name: "cartridge") }
        XCTAssertFalse(model.status.contains("unavailable"), model.status)
        try await wait { FirmwareMenuSelection.contains("Save Cartridge as", in: model.screen) }
        model.send(Data((name + "\r").utf8))
        try await Task.sleep(for: .seconds(1))
        let saved = try await ftp.stat(cartPath)
        XCTAssertGreaterThan(saved?.size ?? 0, 64)
        try await ftp.download(cartPath, to: local) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: local).prefix(16), Data("C64 CARTRIDGE   ".utf8))
        try await api.runPRG(data: Data([1,8,0,0]))
    }

    private func dump(_ model: TelnetMonitorViewModel, name: String) throws {
        let text = (0..<model.screen.rows).map { row in String((0..<model.screen.columns).map { model.screen.cell(atColumn: $0, row: row).character }) }.joined(separator: "\n")
        try text.write(toFile: "/tmp/stream64-live-" + name + ".txt", atomically: true, encoding: .utf8)
    }

    private func enterTemp(_ model: TelnetMonitorViewModel) async throws {
        try await wait { model.status == "Live" }
        for _ in 0..<5 {
            model.send(Data("\u{1B}[D".utf8))
            try await Task.sleep(for: .milliseconds(150))
        }
        try await wait { FirmwareMenuSelection.contains("Temp", in: model.screen) }
        try await model.selectMenuLabel("Temp")
        model.send(Data("\u{1B}[C".utf8))
        try await Task.sleep(for: .milliseconds(400))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for the live firmware state")
        throw URLError(.timedOut)
    }
}
