import XCTest
import CryptoKit
import ZIPFoundation
import MetalKit
import AVFoundation
@testable import Stream64

final class VideoAudioTests: XCTestCase {
    func testCRTScreenColorShaderValuesAreStable() {
        XCTAssertEqual(CRTScreenColor.color.shaderValue, 0)
        XCTAssertEqual(CRTScreenColor.amber.shaderValue, 1)
        XCTAssertEqual(CRTScreenColor.green.shaderValue, 2)
        XCTAssertEqual(CRTScreenColor.blackAndWhite.shaderValue, 3)
        XCTAssertEqual(BezelChoice.c1084.dotPitchMillimeters, 0.42)
        XCTAssertEqual(BezelChoice.c1702.dotPitchMillimeters, 0.64)
    }


    func testStreamPickupRejectsMalformedUDPNoise() {
        XCTAssertFalse(VideoReceiver.isStructurallyValidPacket(
            Data(repeating: 0, count: 46)))
        XCTAssertFalse(AudioReceiver.isStructurallyValidPacket(
            Data(repeating: 0, count: 46)))

        var video = Data(repeating: 0, count: 12 + 384 / 2)
        video[6] = 0x80
        video[7] = 0x01
        video[8] = 1
        video[9] = 4
        XCTAssertTrue(VideoReceiver.isStructurallyValidPacket(video))
        XCTAssertTrue(AudioReceiver.isStructurallyValidPacket(
            Data(repeating: 0, count: 770)))
    }


    func testVideoReceiverPublishesOnlyCompleteMatchingFrames() {
        func packet(
            sequence: UInt16,
            frame: UInt16,
            startLine: Int,
            lines: Int,
            value: UInt8,
            last: Bool
        ) -> Data {
            var data = Data(repeating: 0, count: 12 + 384 * lines / 2)
            data[0] = UInt8(sequence & 0xFF)
            data[1] = UInt8(sequence >> 8)
            data[2] = UInt8(frame & 0xFF)
            data[3] = UInt8(frame >> 8)
            let lineField = UInt16(startLine) | (last ? 0x8000 : 0)
            data[4] = UInt8(lineField & 0xFF)
            data[5] = UInt8(lineField >> 8)
            data[6] = 0x80 // 384 little endian
            data[7] = 0x01
            data[8] = UInt8(lines)
            data[9] = 4
            // encoding is little-endian zero in bytes 10/11.
            for index in 12..<data.count {
                data[index] = value | (value << 4)
            }
            return data
        }

        let receiver = VideoReceiver()
        var frames: [Data] = []
        receiver.onFrame = { frames.append($0) }

        // Missing the first half, so the final packet must not publish a
        // mixed frame.
        receiver.ingest(packet(
            sequence: 1, frame: 10, startLine: 136, lines: 136,
            value: 0x1, last: true))
        XCTAssertTrue(frames.isEmpty)

        // A complete next frame is published, with no stale rows from frame
        // 10 despite its partial data having been received first.
        receiver.ingest(packet(
            sequence: 2, frame: 11, startLine: 0, lines: 136,
            value: 0x2, last: false))
        receiver.ingest(packet(
            sequence: 3, frame: 11, startLine: 136, lines: 136,
            value: 0x2, last: true))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(Set(frames[0]), Set([0x2]))

        // A late packet from the old frame must not create another frame or
        // overwrite the published newer image.
        receiver.ingest(packet(
            sequence: 0, frame: 10, startLine: 0, lines: 136,
            value: 0xF, last: false))
        XCTAssertEqual(frames.count, 1)
    }


    func testVideoReceiverPublishesCompleteNTSCFrames() {
        func packet(
            sequence: UInt16,
            frame: UInt16,
            startLine: Int,
            lines: Int,
            value: UInt8,
            last: Bool
        ) -> Data {
            var data = Data(repeating: 0, count: 12 + 384 * lines / 2)
            data[0] = UInt8(sequence & 0xFF)
            data[1] = UInt8(sequence >> 8)
            data[2] = UInt8(frame & 0xFF)
            data[3] = UInt8(frame >> 8)
            let lineField = UInt16(startLine) | (last ? 0x8000 : 0)
            data[4] = UInt8(lineField & 0xFF)
            data[5] = UInt8(lineField >> 8)
            data[6] = 0x80
            data[7] = 0x01
            data[8] = UInt8(lines)
            data[9] = 4
            for index in 12..<data.count {
                data[index] = value | (value << 4)
            }
            return data
        }

        let receiver = VideoReceiver()
        var frames: [Data] = []
        receiver.onFrame = { frames.append($0) }

        // Ultimate NTSC: 60 × 4-line packets → 384×240. Publishing must not
        // wait for the unused PAL lines 240…271.
        var sequence: UInt16 = 1
        for start in stride(from: 0, to: 240, by: 4) {
            let last = start + 4 >= 240
            receiver.ingest(packet(
                sequence: sequence, frame: 7, startLine: start, lines: 4,
                value: 0x3, last: last))
            sequence &+= 1
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, VideoReceiver.width * VideoReceiver.ntscHeight)
        XCTAssertEqual(Set(frames[0]), Set([0x3]))

        // Incomplete NTSC (missing early rows) must not publish.
        receiver.ingest(packet(
            sequence: sequence, frame: 8, startLine: 120, lines: 4,
            value: 0x4, last: false))
        sequence &+= 1
        receiver.ingest(packet(
            sequence: sequence, frame: 8, startLine: 236, lines: 4,
            value: 0x4, last: true))
        XCTAssertEqual(frames.count, 1)
    }

    func testVideoReceiverStopResetsPartialAssembly() {
        func packet(
            sequence: UInt16,
            frame: UInt16,
            startLine: Int,
            lines: Int,
            value: UInt8,
            last: Bool
        ) -> Data {
            var data = Data(repeating: 0, count: 12 + 384 * lines / 2)
            data[0] = UInt8(sequence & 0xFF)
            data[1] = UInt8(sequence >> 8)
            data[2] = UInt8(frame & 0xFF)
            data[3] = UInt8(frame >> 8)
            let lineField = UInt16(startLine) | (last ? 0x8000 : 0)
            data[4] = UInt8(lineField & 0xFF)
            data[5] = UInt8(lineField >> 8)
            data[6] = 0x80
            data[7] = 0x01
            data[8] = UInt8(lines)
            data[9] = 4
            for index in 12..<data.count {
                data[index] = value | (value << 4)
            }
            return data
        }

        let receiver = VideoReceiver()
        var frames: [Data] = []
        receiver.onFrame = { frames.append($0) }

        // Partial PAL frame, then stop — leftover lines must not combine
        // with a later final packet into a false complete frame.
        receiver.ingest(packet(
            sequence: 1, frame: 1, startLine: 0, lines: 136,
            value: 0x1, last: false))
        receiver.stop()
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        receiver.ingest(packet(
            sequence: 2, frame: 1, startLine: 136, lines: 136,
            value: 0x2, last: true))
        XCTAssertTrue(frames.isEmpty)
    }

    @MainActor
    func testMemoryConsoleParsesAddressAndHexBytes() {
        XCTAssertEqual(MemoryConsoleViewModel.parseAddress("$D020"), 0xD020)
        XCTAssertEqual(MemoryConsoleViewModel.parseAddress("0xc000"), 0xC000)
        XCTAssertNil(MemoryConsoleViewModel.parseAddress("GGGG"))
        XCTAssertEqual(
            MemoryConsoleViewModel.parseHexBytes("A9 00, FF"),
            [0xA9, 0x00, 0xFF])
        XCTAssertNil(MemoryConsoleViewModel.parseHexBytes("ZZ"))
        let dump = MemoryConsoleViewModel.formatHexDump(
            Data([0x41, 0x00, 0x7E]), start: 0x0400)
        XCTAssertTrue(dump.contains("0400"))
        XCTAssertTrue(dump.contains("41 00 7E"))
        XCTAssertTrue(dump.contains("|A.~|"))
    }


    func testAudioReceiverCombinesSelectionAndAirPlayMuteGates() {
        let receiver = AudioReceiver()
        receiver.volume = 0.65
        XCTAssertEqual(receiver.effectiveLocalVolume, 0.65, accuracy: 0.0001)

        receiver.muted = true
        XCTAssertEqual(receiver.effectiveLocalVolume, 0)
        receiver.muted = false
        XCTAssertEqual(receiver.effectiveLocalVolume, 0.65, accuracy: 0.0001)

        receiver.externalOutputSuppressed = true
        XCTAssertEqual(receiver.effectiveLocalVolume, 0)
        receiver.muted = true
        receiver.externalOutputSuppressed = false
        XCTAssertEqual(receiver.effectiveLocalVolume, 0)
        receiver.muted = false
        XCTAssertEqual(receiver.effectiveLocalVolume, 0.65, accuracy: 0.0001)
    }


    func testDiscoveryHostsStayBoundedAndExcludeLocalAddress() {
        let interface = LocalNetwork.IPv4Interface(
            name: "en0",
            address: "172.16.10.15",
            netmask: "255.255.0.0")

        let hosts = LocalNetwork.discoveryHosts(for: [interface])

        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "172.16.10.1")
        XCTAssertEqual(hosts.last, "172.16.10.254")
        XCTAssertFalse(hosts.contains("172.16.10.15"))
        XCTAssertFalse(hosts.contains("172.16.11.1"))
    }


    func testDiscoveryHostsDeduplicateOverlappingInterfaces() {
        let interfaces = [
            LocalNetwork.IPv4Interface(
                name: "en0", address: "192.168.1.10",
                netmask: "255.255.255.0"),
            LocalNetwork.IPv4Interface(
                name: "en1", address: "192.168.1.11",
                netmask: "255.255.255.0"),
        ]

        let hosts = LocalNetwork.discoveryHosts(for: interfaces)

        XCTAssertEqual(hosts.count, 252)
        XCTAssertEqual(Set(hosts).count, hosts.count)
        XCTAssertFalse(hosts.contains("192.168.1.10"))
        XCTAssertFalse(hosts.contains("192.168.1.11"))
    }


    @MainActor
    func testDiscoveryDeduplicatesDevicesByUniqueID() async throws {
        let service = DeviceDiscoveryService(
            maximumConcurrentProbes: 2,
            hostProvider: {
                ["192.168.1.20", "192.168.1.21", "192.168.1.22"]
            },
            probe: { host in
                DeviceDiscoveryService.DiscoveredDevice(
                    host: host,
                    product: "Ultimate 64",
                    firmwareVersion: "3.14",
                    hostname: nil,
                    uniqueID: host == "192.168.1.22" ? "second" : "first")
            })

        service.start()
        while service.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(service.scannedHostCount, 3)
        XCTAssertEqual(Set(service.results.map(\.id)), ["first", "second"])
    }


    func testDiscoveryRejectsEmptyIdentityAndNormalizesInfo() throws {
        let emptyInfo = UltimateAPIClient.DeviceInfo(
            product: nil,
            firmwareVersion: nil,
            hostname: "untrusted-host",
            uniqueId: nil)
        XCTAssertNil(DeviceDiscoveryService.discoveryResult(
            host: "192.168.1.30", info: emptyInfo))

        let validInfo = UltimateAPIClient.DeviceInfo(
            product: "  Ultimate 64-II ",
            firmwareVersion: " 3.14d ",
            hostname: " Ultimate-64 ",
            uniqueId: " B94F01 ")
        let result = try XCTUnwrap(
            DeviceDiscoveryService.discoveryResult(
                host: "192.168.1.31", info: validInfo))

        XCTAssertEqual(result.product, "Ultimate 64-II")
        XCTAssertEqual(result.firmwareVersion, "3.14d")
        XCTAssertEqual(result.hostname, "Ultimate-64")
        XCTAssertEqual(result.uniqueID, "B94F01")
    }

    func testC64UltimateFounderInfoNormalizesLegacyFirmwareLabel() throws {
        let founder = UltimateAPIClient.DeviceInfo(
            product: "C64 Ultimate",
            firmwareVersion: "3.14",
            hostname: "C64U-FOUNDER",
            uniqueId: "5D0118")
        XCTAssertEqual(founder.displayProduct, "C64 Ultimate Founder")
        XCTAssertEqual(founder.displayFirmwareVersion, "1.0.0")
        XCTAssertEqual(
            founder.connectionDescription,
            "C64 Ultimate Founder · 1.0.0")

        let discovered = try XCTUnwrap(
            DeviceDiscoveryService.discoveryResult(
                host: "172.16.10.64", info: founder))
        XCTAssertEqual(discovered.product, "C64 Ultimate Founder")
        XCTAssertEqual(discovered.firmwareVersion, "1.0.0")

        // Ultimate 64's real 3.14d line must not be rewritten.
        let u64 = UltimateAPIClient.DeviceInfo(
            product: "Ultimate 64",
            firmwareVersion: "3.14d",
            hostname: "u64",
            uniqueId: nil)
        XCTAssertEqual(u64.displayFirmwareVersion, "3.14d")
        XCTAssertEqual(u64.displayProduct, "Ultimate 64")
    }


    func testDefaultDeviceAvoidsExistingStreamPorts() {
        let existing = [
            UltimateDevice(
                name: "One", host: "192.168.1.20",
                videoPort: 11000, audioPort: 11001, debugPort: 11002),
            UltimateDevice(
                name: "Two", host: "192.168.1.21",
                videoPort: 11003, audioPort: 11004, debugPort: 11005),
        ]

        let device = UltimateDevice.makeDefault(avoiding: existing)

        XCTAssertEqual(device.videoPort, 11006)
        XCTAssertEqual(device.audioPort, 11007)
        XCTAssertEqual(device.debugPort, 11008)
    }


    func testDevicePortValidationRejectsRangesAndCollisions() {
        var device = UltimateDevice.makeDefault()
        device.host = "192.0.2.10"
        XCTAssertNil(device.portValidationIssue(among: []))

        device.videoPort = -1
        XCTAssertNotNil(device.portValidationIssue(among: []))
        device.videoPort = 65_536
        XCTAssertNotNil(device.portValidationIssue(among: []))

        device.videoPort = 11_000
        device.audioPort = 11_000
        XCTAssertNotNil(device.portValidationIssue(among: []))

        device.audioPort = 11_001
        device.debugPort = 11_002
        let other = UltimateDevice(
            name: "Other",
            host: "192.0.2.11",
            videoPort: 11_002,
            audioPort: 12_001,
            debugPort: 12_002)
        XCTAssertEqual(
            device.portValidationIssue(among: [other]),
            "Local stream port 11002 is already used by another device.")

        device.debugPort = 11_003
        device.apiPort = 0
        XCTAssertNotNil(device.portValidationIssue(among: [other]))
        device.apiPort = 80
        device.ftpPort = 70_000
        XCTAssertNotNil(device.portValidationIssue(among: [other]))
    }


    @MainActor
    func testTogglePauseOnlyChangesStateAfterSuccessfulCommand() async {
        let device = UltimateDevice(
            name: "Pause", host: "192.0.2.1")
        let session = DeviceSession(
            device: device,
            settings: AppSettings())

        XCTAssertFalse(session.isPaused)
        await session.togglePause()
        XCTAssertFalse(
            session.isPaused,
            "failed REST pause must not optimistically change local state")
    }


    @MainActor
    func testSessionManagerEvictsRemovedAndReplacedSessions() async {
        let manager = SessionManager()
        let settings = AppSettings()
        var device = UltimateDevice.makeDefault()
        device.host = "127.0.0.1"

        let original = manager.session(for: device, settings: settings)
        XCTAssertEqual(manager.cachedSessionCount, 1)
        XCTAssertTrue(manager.hasCachedSession(id: device.id))

        var edited = device
        edited.name = "Edited device"
        let replacement = manager.session(for: edited, settings: settings)
        XCTAssertFalse(original === replacement)
        XCTAssertEqual(manager.cachedSessionCount, 1)
        XCTAssertTrue(manager.hasCachedSession(id: device.id))

        await manager.removeSession(id: device.id)
        XCTAssertEqual(manager.cachedSessionCount, 0)
        XCTAssertFalse(manager.hasCachedSession(id: device.id))
    }


    @MainActor
    func testLiveSessionRemoveAndReaddWhenConfigured() async throws {
        guard let host = ProcessInfo.processInfo.environment[
            "UV_LIVE_SESSION_HOST"],
            !host.isEmpty else {
            throw XCTSkip(
                "Set UV_LIVE_SESSION_HOST for live session lifecycle validation")
        }

        let manager = SessionManager()
        let settings = AppSettings()
        var device = UltimateDevice.makeDefault()
        device.host = host
        device.videoPort = 12_100
        device.audioPort = 12_101
        device.debugPort = 12_102

        let first = manager.session(for: device, settings: settings)
        await first.connect()
        XCTAssertTrue(first.isConnected)
        let firstBaseline = first.videoReceiver.packetsReceived
        for _ in 0..<100
        where first.videoReceiver.packetsReceived == firstBaseline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(
            first.videoReceiver.packetsReceived,
            firstBaseline,
            "first session received no live video packets")

        await manager.removeSession(id: device.id)
        XCTAssertFalse(manager.hasCachedSession(id: device.id))

        let second = manager.session(for: device, settings: settings)
        XCTAssertFalse(first === second)
        await second.connect()
        XCTAssertTrue(second.isConnected)
        let secondBaseline = second.videoReceiver.packetsReceived
        for _ in 0..<100
        where second.videoReceiver.packetsReceived == secondBaseline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(
            second.videoReceiver.packetsReceived,
            secondBaseline,
            "re-added session received no live video packets")

        await manager.removeSession(id: device.id)
    }


    func testDebugStreamEntryDecodes6510VICWordLayout() {
        let word: UInt32 = (1 << 31)             // PHI2
            | (0 << 30)                          // GAME# = 0
            | (1 << 29)                          // EXROM# = 1
            | (1 << 28)                          // BA = 1
            | (0 << 27)                          // IRQ# = 0
            | (1 << 26)                          // ROM# = 1
            | (0 << 25)                          // NMI# = 0
            | (1 << 24)                          // R/W# = read
            | (UInt32(0xAB) << 16)                // Data
            | UInt32(0x1234)                      // Address

        let entry = DebugStreamEntry(word: word, source: .cpu6510)
        XCTAssertTrue(entry.phi2)
        XCTAssertFalse(entry.game)
        XCTAssertTrue(entry.exrom)
        XCTAssertTrue(entry.ba)
        XCTAssertFalse(entry.irq)
        XCTAssertTrue(entry.rom)
        XCTAssertFalse(entry.nmi)
        XCTAssertTrue(entry.isRead)
        XCTAssertEqual(entry.data, 0xAB)
        XCTAssertEqual(entry.address, 0x1234)
    }


    func testDebugStreamEntryDecodes1541WordLayout() {
        let word: UInt32 = (0 << 31)
            | (1 << 30)                           // ATN
            | (0 << 29)                           // DATA
            | (1 << 28)                           // CLOCK
            | (1 << 27)                           // SYNC
            | (0 << 26)                           // BYTE_READY
            | (1 << 25)                           // IRQ#
            | (0 << 24)                           // R/W# = write
            | (UInt32(0x55) << 16)
            | UInt32(0x0300)

        let entry = DebugStreamEntry(word: word, source: .drive1541)
        XCTAssertFalse(entry.phi2)
        XCTAssertTrue(entry.atn)
        XCTAssertFalse(entry.dataLine)
        XCTAssertTrue(entry.clock)
        XCTAssertTrue(entry.sync)
        XCTAssertFalse(entry.byteReady)
        XCTAssertTrue(entry.irq)
        XCTAssertFalse(entry.isRead)
        XCTAssertEqual(entry.data, 0x55)
        XCTAssertEqual(entry.address, 0x0300)
    }


    func testDebugStreamPacketParsingDecodesSequenceAndMultipleEntries() {
        var packet = Data([0x05, 0x16, 0x00, 0x00]) // seq 0x1605, reserved
        let word1: UInt32 = (1 << 31) | (1 << 24) | (UInt32(0x20) << 16) | 0x0400
        let word2: UInt32 = (UInt32(0x02) << 16) | 0xD020
        for word in [word1, word2] {
            packet.append(contentsOf: [
                UInt8(word & 0xFF),
                UInt8((word >> 8) & 0xFF),
                UInt8((word >> 16) & 0xFF),
                UInt8((word >> 24) & 0xFF),
            ])
        }

        let (sequence, entries) = DebugStreamEntry.parsePacket(packet, source: .cpu6510)
        XCTAssertEqual(sequence, 0x1605)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].address, 0x0400)
        XCTAssertEqual(entries[0].data, 0x20)
        XCTAssertTrue(entries[0].isRead)
        XCTAssertEqual(entries[1].address, 0xD020)
        XCTAssertEqual(entries[1].data, 0x02)
        XCTAssertFalse(entries[1].isRead)
    }


    func testDebugStreamMissedPacketCountHandlesGapsDuplicatesReorderingAndWrap() {
        func packet(_ sequence: UInt16) -> Data {
            Data([
                UInt8(sequence & 0xFF),
                UInt8(sequence >> 8),
                0, 0,
            ])
        }

        let receiver = DebugStreamReceiver()
        receiver.ingest(packet(100))
        receiver.ingest(packet(103))
        XCTAssertEqual(receiver.missedPackets, 2)

        receiver.ingest(packet(103)) // duplicate
        receiver.ingest(packet(102)) // late/reordered
        XCTAssertEqual(receiver.missedPackets, 2)

        let wrapping = DebugStreamReceiver()
        wrapping.ingest(packet(65_535))
        wrapping.ingest(packet(0))
        wrapping.ingest(packet(2))
        XCTAssertEqual(wrapping.missedPackets, 1)
    }


    func testMemoryHeatmapRecordsReadsAndWritesIndependently() throws {
        let heatmap = MemoryHeatmap()
        let readWord: UInt32 = (1 << 24) | (UInt32(0x3C) << 16) | UInt32(0x1234)
        let writeWord: UInt32 = (UInt32(0xA5) << 16) | UInt32(0x5678)
        let readEntry = DebugStreamEntry(word: readWord, source: .cpu6510)
        let writeEntry = DebugStreamEntry(word: writeWord, source: .cpu6510)

        heatmap.record([readEntry, writeEntry])

        let readState = try XCTUnwrap(heatmap.state(at: 0x1234))
        let writeState = try XCTUnwrap(heatmap.state(at: 0x5678))
        XCTAssertGreaterThan(readState.lastRead, 0)
        XCTAssertEqual(readState.lastWrite, 0)
        XCTAssertGreaterThan(writeState.lastWrite, 0)
        XCTAssertEqual(writeState.lastRead, 0)
        XCTAssertTrue(readState.lastAccessWasRead)
        XCTAssertFalse(writeState.lastAccessWasRead)
        XCTAssertEqual(readState.lastValue, 0x3C)
        XCTAssertEqual(writeState.lastValue, 0xA5)

        heatmap.reset()
        let resetRead = try XCTUnwrap(heatmap.state(at: 0x1234))
        let resetWrite = try XCTUnwrap(heatmap.state(at: 0x5678))
        XCTAssertEqual(resetRead.lastRead, 0)
        XCTAssertEqual(resetWrite.lastWrite, 0)
        XCTAssertEqual(resetRead.lastAccess, 0)
        XCTAssertEqual(resetWrite.lastAccess, 0)
        XCTAssertEqual(resetRead.lastValue, 0)
        XCTAssertEqual(resetWrite.lastValue, 0)
    }

    /// Regression test for direction being inferred from timestamps.
    /// Read-modify-write accesses can share one timestamp in a batch, while
    /// artificial timestamp offsets can overlap a following batch. In both
    /// cases a later read/write could retain the preceding access's color.
    /// Explicit direction tracking must follow exact array/bus order.


    func testMemoryHeatmapPreservesOrderForReadThenWriteToSameAddressInOneBatch() throws {
        let heatmap = MemoryHeatmap()
        let readWord: UInt32 = (1 << 24) | (UInt32(0x10) << 16) | UInt32(0xD020)
        let writeWord: UInt32 = (UInt32(0xF0) << 16) | UInt32(0xD020)
        let readEntry = DebugStreamEntry(word: readWord, source: .cpu6510)
        let writeEntry = DebugStreamEntry(word: writeWord, source: .cpu6510)

        heatmap.record([readEntry, writeEntry])

        var state = try XCTUnwrap(heatmap.state(at: 0xD020))
        XCTAssertFalse(
            state.lastAccessWasRead,
            "the write happened after the read on the real bus, so it must win")
        XCTAssertEqual(state.lastValue, 0xF0)

        // The reverse order (write then read, as a plain load right after a
        // store) must resolve the other way.
        heatmap.reset()
        heatmap.record([writeEntry, readEntry])
        state = try XCTUnwrap(heatmap.state(at: 0xD020))
        XCTAssertTrue(
            state.lastAccessWasRead,
            "the read happened after the write on the real bus, so it must win")
        XCTAssertEqual(state.lastValue, 0x10)
    }


    func testMemoryHeatmapSupportsConcurrentRecordResetAndSnapshot() {
        let heatmap = MemoryHeatmap()
        let read = DebugStreamEntry(
            word: (1 << 24) | (UInt32(0x55) << 16) | 0x2000,
            source: .cpu6510)
        let write = DebugStreamEntry(
            word: (UInt32(0xAA) << 16) | 0xD020,
            source: .cpu6510)
        let failureLock = NSLock()
        var invalidSnapshot = false

        DispatchQueue.concurrentPerform(iterations: 6) { worker in
            switch worker {
            case 0...3:
                for _ in 0..<500 {
                    heatmap.record([read, write])
                }
            case 4:
                for _ in 0..<150 {
                    let snapshot = heatmap.renderSnapshot()
                    if snapshot.lastAccess.count != MemoryHeatmap.addressSpace
                        || snapshot.lastAccessWasRead.count
                            != MemoryHeatmap.addressSpace
                        || snapshot.lastValue.count
                            != MemoryHeatmap.addressSpace {
                        failureLock.lock()
                        invalidSnapshot = true
                        failureLock.unlock()
                    }
                }
            default:
                for _ in 0..<100 {
                    heatmap.reset()
                    _ = heatmap.renderSnapshot()
                }
            }
        }

        XCTAssertFalse(invalidSnapshot)
        XCTAssertEqual(
            heatmap.renderSnapshot().lastValue.count,
            MemoryHeatmap.addressSpace)
    }


    func testMemoryHeatmapSnapshotPreservesRecordedValuesOutsideWriterLock() {
        let heatmap = MemoryHeatmap()
        let write = DebugStreamEntry(
            word: (UInt32(0xC0) << 16) | 0x0400,
            source: .cpu6510)
        heatmap.record([write])
        let snapshot = heatmap.renderSnapshot()
        XCTAssertGreaterThan(snapshot.generation, 0)
        XCTAssertEqual(snapshot.lastValue[0x0400], 0xC0)
        XCTAssertFalse(snapshot.lastAccessWasRead[0x0400])
        XCTAssertGreaterThan(snapshot.lastAccess[0x0400], 0)
    }


    func testMemoryHeatmapCurrentGenerationTracksRecordAndReset() {
        let heatmap = MemoryHeatmap()
        let initial = heatmap.currentGeneration()
        let write = DebugStreamEntry(
            word: (UInt32(0x11) << 16) | 0x1000,
            source: .cpu6510)
        heatmap.record([write])
        let afterRecord = heatmap.currentGeneration()
        XCTAssertGreaterThan(afterRecord, initial)
        heatmap.reset()
        XCTAssertGreaterThan(heatmap.currentGeneration(), afterRecord)
    }


    func testMemoryMap3DTickActionSkipsSnapshotWhenStable() {
        XCTAssertEqual(
            MemoryMap3DRenderer.tickAction(
                generation: 3,
                lastGeneration: 3,
                blockSize: 2,
                lastLOD: 2,
                activityPulse: false,
                stableTickParity: 0,
                videoGPUBehind: false),
            .skip)
        XCTAssertEqual(
            MemoryMap3DRenderer.tickAction(
                generation: 3,
                lastGeneration: 3,
                blockSize: 2,
                lastLOD: 2,
                activityPulse: true,
                stableTickParity: 0,
                videoGPUBehind: false),
            .redrawOnly)
        XCTAssertEqual(
            MemoryMap3DRenderer.tickAction(
                generation: 3,
                lastGeneration: 3,
                blockSize: 2,
                lastLOD: 2,
                activityPulse: true,
                stableTickParity: 1,
                videoGPUBehind: false),
            .skip)
        XCTAssertEqual(
            MemoryMap3DRenderer.tickAction(
                generation: 4,
                lastGeneration: 3,
                blockSize: 2,
                lastLOD: 2,
                activityPulse: true,
                stableTickParity: 0,
                videoGPUBehind: false),
            .rebuild)
        XCTAssertEqual(
            MemoryMap3DRenderer.tickAction(
                generation: 4,
                lastGeneration: 3,
                blockSize: 2,
                lastLOD: 2,
                activityPulse: true,
                stableTickParity: 0,
                videoGPUBehind: true),
            .skip)
    }


    func testVideoScalingIntegerFallsBackWhenUtilizationIsPoor() {
        // 800pt-tall / wide enough for 4:3 fit → fit height 800, 2× integer
        // is only 544 (~68%), so Integer should fall back (return nil).
        XCTAssertNil(
            VideoScaling.integerScaleFactor(viewWidth: 1200, viewHeight: 800))

        // 1080p-class height: 3× (816) uses ~76% of fit → keep integer.
        XCTAssertEqual(
            VideoScaling.integerScaleFactor(viewWidth: 1920, viewHeight: 1080),
            3)

        // Fit is continuous while preserving aspect; Integer retains its
        // existing utilization fallback behavior on small windows.
        let tiny = CGSize(width: 640, height: 400)
        let fit = VideoScaling.scaleFactors(mode: .aspectFit, drawableSize: tiny)
        let smartInteger = VideoScaling.scaleFactors(
            mode: .integer, drawableSize: tiny)
        XCTAssertEqual(fit.x, smartInteger.x, accuracy: 0.0001)
        XCTAssertEqual(fit.y, smartInteger.y, accuracy: 0.0001)
    }


    func testMemoryMap3DFillInstancesPacksNonZeroBlocks() {
        var values = [UInt8](repeating: 0, count: MemoryHeatmap.addressSpace)
        var accessTimes = [Double](repeating: 0, count: MemoryHeatmap.addressSpace)
        var directions = [Bool](repeating: true, count: MemoryHeatmap.addressSpace)
        values[0] = 128
        accessTimes[0] = 100
        values[257] = 64 // (1,1) in a 2×2 block with origin (0,0) when blockSize=2
        accessTimes[257] = 101
        directions[257] = false

        let buffer = UnsafeMutablePointer<MemoryMap3DRenderer.InstanceData>.allocate(
            capacity: 16)
        defer { buffer.deallocate() }
        let count = MemoryMap3DRenderer.fillInstances(
            values: values,
            accessTimes: accessTimes,
            directions: directions,
            blockSize: 2,
            timeBase: 99,
            destination: buffer)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(buffer[0].coordinate & 0xFFFF, 0)
        XCTAssertEqual((buffer[0].coordinate >> 16) & 0xFFFF, 0)
        XCTAssertEqual(buffer[0].packedValueFlagsAndSpan & 0xFF, 96) // (128+64)/2
    }


    @MainActor
    func testAcquireDebugTraceReturnsNilWhenDisconnected() async {
        let session = DeviceSession(
            device: UltimateDevice(
                name: "Debug Lease",
                host: "192.0.2.20"),
            settings: AppSettings())
        let token = await session.acquireDebugTrace(mode: .cpu6510Only)
        XCTAssertNil(token)
        XCTAssertEqual(session.debugTraceState, .inactive)
    }


    func testDebugStreamPacketParsingToleratesShortPacket() {
        let (sequence, entries) = DebugStreamEntry.parsePacket(Data([0x01]), source: .vic)
        XCTAssertEqual(sequence, 0)
        XCTAssertTrue(entries.isEmpty)
    }


    func testDebugRegisterValueRoundTripsThroughHexEncoding() async throws {
        let transport = DebugRegisterHTTPTransport()
        let client = UltimateAPIClient(
            device: UltimateDevice(name: "Debug", host: "192.168.1.64"),
            transport: transport)

        let value = try await client.writeDebugRegister(0x0A)
        XCTAssertEqual(value, 0x2C)
        let request = await transport.lastRequest
        XCTAssertEqual(request?.url?.path, "/v1/machine:debugreg")
        XCTAssertEqual(request?.httpMethod, "PUT")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request?.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "value" })?.value,
            "0A")
    }


    @MainActor
    func testOldDisplaySnapshotDefaultsToColorCRT() throws {
        let id = UUID()
        let key = "displaySettings.\(id.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let oldSnapshot: [String: Any] = [
            "scalingMode": ScalingMode.aspectFit.rawValue,
            "filterMode": FilterMode.crtTube.rawValue,
            "palette": PaletteChoice.colodore.rawValue,
            "tubeInput": TubeInput.composite.rawValue,
            "showFPS": true,
            "showBezel": true,
            "bezelStyle": BezelChoice.c1702.rawValue,
            "bezelReflection": true,
            "monBrightness": 0.4,
            "monContrast": 0.6,
            "monColor": 0.7,
            "monTint": 0.5,
        ]
        UserDefaults.standard.set(
            try JSONSerialization.data(withJSONObject: oldSnapshot),
            forKey: key)

        let display = DisplaySettings(deviceID: id)
        XCTAssertEqual(display.crtScreenColor, .color)
        XCTAssertFalse(display.crtDirtyGlass)
        XCTAssertEqual(display.filterMode, .crtTube)
        XCTAssertEqual(display.palette, .colodore)
        XCTAssertEqual(display.crtScanlineStrength, 0.5, accuracy: 0.0001)
        XCTAssertEqual(display.crtBloomAmount, 0.5, accuracy: 0.0001)
        XCTAssertEqual(display.crtMaskIntensity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(display.crtBarrelDistortion, 0.5, accuracy: 0.0001)
        XCTAssertEqual(display.optics.scanlineStrength, 0.5, accuracy: 0.0001)
    }


    @MainActor
    func testCRTOpticsPersistPerDevice() throws {
        let id = UUID()
        let key = "displaySettings.\(id.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let display = DisplaySettings(deviceID: id)
        display.crtScanlineStrength = 0.2
        display.crtBloomAmount = 0.8
        display.crtMaskIntensity = 0.1
        display.crtBarrelDistortion = 0.9

        let reloaded = DisplaySettings(deviceID: id)
        XCTAssertEqual(reloaded.crtScanlineStrength, 0.2, accuracy: 0.0001)
        XCTAssertEqual(reloaded.crtBloomAmount, 0.8, accuracy: 0.0001)
        XCTAssertEqual(reloaded.crtMaskIntensity, 0.1, accuracy: 0.0001)
        XCTAssertEqual(reloaded.crtBarrelDistortion, 0.9, accuracy: 0.0001)
        XCTAssertEqual(reloaded.optics.bloomAmount, 0.8, accuracy: 0.0001)
    }


    @MainActor
    func testEmbeddedMetalShadersCompile() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable")
        }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertNotNil(MetalFrameRenderer(mtkView: view))
    }


    func testMemoryMap3DInstanceEncodingPreservesValueAndDirection() {
        XCTAssertEqual(
            MemoryMap3DInstanceEncoding.normalizedHeight(for: 0x00),
            0,
            accuracy: 0.0001)
        XCTAssertEqual(
            MemoryMap3DInstanceEncoding.normalizedHeight(for: 0x80),
            128.0 / 255.0,
            accuracy: 0.0001)
        XCTAssertEqual(
            MemoryMap3DInstanceEncoding.normalizedHeight(for: 0xFF),
            1,
            accuracy: 0.0001)
        XCTAssertEqual(
            MemoryMap3DInstanceEncoding.flags(
                accessed: false, wasRead: true),
            0)
        XCTAssertEqual(
            MemoryMap3DInstanceEncoding.flags(
                accessed: true, wasRead: true),
            0x01)
        XCTAssertEqual(
            MemoryMap3DInstanceEncoding.flags(
                accessed: true, wasRead: false),
            0x03)
    }


    func testMemoryMap3DCameraClampsAndResets() {
        var camera = MemoryMap3DCamera()
        camera.rotate(deltaX: 100, deltaY: 1000)
        XCTAssertEqual(
            camera.pitch,
            MemoryMap3DCamera.minimumPitch,
            accuracy: 0.0001)
        camera.rotate(deltaX: 0, deltaY: -1000)
        XCTAssertEqual(
            camera.pitch,
            MemoryMap3DCamera.maximumPitch,
            accuracy: 0.0001)

        camera.zoom(scrollDelta: -1000)
        XCTAssertEqual(
            camera.distance,
            MemoryMap3DCamera.minimumDistance,
            accuracy: 0.0001)
        camera.zoom(scrollDelta: 1000)
        XCTAssertEqual(
            camera.distance,
            MemoryMap3DCamera.maximumDistance,
            accuracy: 0.0001)

        camera.reset()
        XCTAssertEqual(camera.yaw, MemoryMap3DCamera.defaultYaw)
        XCTAssertEqual(camera.pitch, MemoryMap3DCamera.defaultPitch)
        XCTAssertEqual(camera.distance, MemoryMap3DCamera.defaultDistance)
    }


    func testMemoryMap3DLODActivityAndRegions() {
        let defaults = MemoryMap3DOptions()
        XCTAssertTrue(defaults.adaptiveLOD)
        XCTAssertTrue(defaults.hoverInspection)
        XCTAssertTrue(defaults.regionOverlays)
        XCTAssertTrue(defaults.activityPulse)

        XCTAssertEqual(
            MemoryMap3DRenderer.lodBlockSize(for: 1.0), 1)
        XCTAssertEqual(
            MemoryMap3DRenderer.lodBlockSize(for: 1.8), 2)
        XCTAssertEqual(
            MemoryMap3DRenderer.lodBlockSize(for: 2.8), 4)
        XCTAssertEqual(
            MemoryMap3DRenderer.lodBlockSize(for: 3.8), 8)

        XCTAssertEqual(
            MemoryMap3DRenderer.activityIntensity(
                accessedAt: 10, now: 10),
            1,
            accuracy: 0.0001)
        XCTAssertEqual(
            MemoryMap3DRenderer.activityIntensity(
                accessedAt: 10, now: 10.35),
            0,
            accuracy: 0.0001)
        // Shader path uses the same decay curve from uploaded timestamps;
        // keep the CPU helper as the reference for that math.
        XCTAssertEqual(
            MemoryMap3DRenderer.activityIntensity(
                accessedAt: 10, now: 10.175),
            0.25,
            accuracy: 0.0001)

        XCTAssertEqual(
            MemoryMap3DRenderer.regionName(
                for: 0xD020, source: .cpu6510),
            "VIC-II / Character ROM")
        XCTAssertEqual(
            MemoryMap3DRenderer.regionName(
                for: 0x01F0, source: .cpu6510),
            "Stack")
        XCTAssertEqual(
            MemoryMap3DRenderer.regionName(
                for: 0x1800, source: .drive1541),
            "1541 VIA1 (IEC)")
    }


    @MainActor
    func testMemoryMap3DMetalShaderAndRendererCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        XCTAssertNoThrow(
            try device.makeLibrary(
                source: MemoryMap3DRenderer.shaderSource,
                options: nil))

        let view = MTKView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            device: device)
        XCTAssertNotNil(
            MemoryMap3DRenderer(
                mtkView: view,
                heatmap: MemoryHeatmap()))
    }


    func testLiveHLSServerPlaylistRollsAndParsesRanges() {
        let server = LiveHLSServer(maximumSegments: 3)
        server.setInitializationSegment(Data([0, 1, 2]))
        for index in 0..<5 {
            server.appendMediaSegment(
                Data(repeating: UInt8(index), count: 16),
                duration: 0.5,
                discontinuity: index == 3)
        }

        let playlist = server.playlist()
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:2"))
        XCTAssertFalse(playlist.contains("segment0.m4s"))
        XCTAssertTrue(playlist.contains("segment2.m4s"))
        XCTAssertTrue(playlist.contains("segment4.m4s"))
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY"))
        XCTAssertEqual(server.mediaSegmentCount, 3)
        XCTAssertTrue(server.hasInitializationSegment)

        XCTAssertEqual(
            LiveHLSServer.byteRange(
                from: "Range: bytes=4-9", length: 20),
            4...9)
        XCTAssertEqual(
            LiveHLSServer.byteRange(
                from: "Range: bytes=15-", length: 20),
            15...19)
        XCTAssertNil(
            LiveHLSServer.byteRange(
                from: "Range: bytes=30-40", length: 20))
    }


    func testLiveHLSServerServesAuthenticatedPlaylist() throws {
        let server = LiveHLSServer(maximumSegments: 3)
        server.setInitializationSegment(Data([0, 1, 2]))
        server.appendMediaSegment(
            Data(repeating: 7, count: 32),
            duration: 0.5)

        let ready = expectation(description: "HLS server ready")
        var result: Result<URL, Error>?
        server.start {
            result = $0
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3)
        defer { server.stop() }

        let url = try XCTUnwrap(try result?.get())
        let playlist = try String(
            contentsOf: url,
            encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXTM3U"))
        XCTAssertTrue(playlist.contains("segment0.m4s"))

        let invalidURL = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("wrong/stream.m3u8")
        XCTAssertThrowsError(try Data(contentsOf: invalidURL))
    }


    func testLiveAirPlayEncoderProducesPlayableSegments() throws {
        let server = LiveHLSServer(maximumSegments: 8)
        let encoder = LiveAirPlayEncoder(server: server)
        var failure: Error?
        encoder.onFailure = { failure = $0 }
        try encoder.start()

        var phase = 0.0
        let phaseStep = 2 * Double.pi * 440 /
            LiveAirPlayEncoder.sourceSampleRate
        for _ in 0..<700 {
            var samples = [Float]()
            samples.reserveCapacity(192 * 2)
            for _ in 0..<192 {
                let value = Float(sin(phase) * 0.25)
                phase += phaseStep
                samples.append(value)
                samples.append(value)
            }
            encoder.enqueue(samples: samples)
        }

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline,
              (!server.hasInitializationSegment ||
               server.mediaSegmentCount == 0),
              failure == nil {
            Thread.sleep(forTimeInterval: 0.02)
        }
        encoder.stop()

        XCTAssertNil(failure)
        XCTAssertTrue(server.hasInitializationSegment)
        XCTAssertGreaterThan(server.mediaSegmentCount, 0)
        guard let fragment = server.firstPlayableFragment() else {
            return XCTFail("No playable fragmented MP4 was produced")
        }
        XCTAssertGreaterThan(fragment.count, 1_000)
    }


    func testLiveAirPlayEncoderMaintainsTimelineWithSilence() throws {
        let server = LiveHLSServer(maximumSegments: 4)
        let encoder = LiveAirPlayEncoder(server: server)
        try encoder.start()
        defer { encoder.stop() }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              server.mediaSegmentCount == 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(server.hasInitializationSegment)
        XCTAssertGreaterThan(
            server.mediaSegmentCount,
            0,
            "AirPlay HLS must continue through source-switch/reconnect gaps")
    }


    func testAVPlayerLoadsGeneratedLiveAirPlayHLS() throws {
        let server = LiveHLSServer(maximumSegments: 8)
        let ready = expectation(description: "HLS origin ready")
        var serverResult: Result<URL, Error>?
        server.start {
            serverResult = $0
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3)
        defer { server.stop() }
        let url = try XCTUnwrap(try serverResult?.get())

        let encoder = LiveAirPlayEncoder(server: server)
        try encoder.start()
        defer { encoder.stop() }
        for packet in 0..<700 {
            let value = Float(sin(Double(packet) * 0.03) * 0.2)
            encoder.enqueue(
                samples: [Float](repeating: value, count: 192 * 2))
        }
        let segmentDeadline = Date().addingTimeInterval(5)
        while Date() < segmentDeadline,
              server.mediaSegmentCount == 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertGreaterThan(server.mediaSegmentCount, 0)

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause() }

        let playerDeadline = Date().addingTimeInterval(8)
        while Date() < playerDeadline,
              item.status == .unknown {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(
            item.status,
            .readyToPlay,
            item.error?.localizedDescription ?? "AVPlayer did not load live HLS")
    }


}
