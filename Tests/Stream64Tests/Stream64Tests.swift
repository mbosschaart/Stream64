import XCTest
import CryptoKit
import ZIPFoundation
import MetalKit
import AVFoundation
@testable import Stream64

private final class StaticUpdateTransport: UpdateHTTPTransport, @unchecked Sendable {
    let data: Data
    let statusCode: Int

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil)!
        )
    }
}

final class Assembly64FeatureTests: XCTestCase {
    func testUpdateVersionComparisonSupportsStream64BetaVersions() {
        XCTAssertLessThan(
            Stream64ReleaseVersion("0.102b")!,
            Stream64ReleaseVersion("0.103b")!)
        XCTAssertLessThan(
            Stream64ReleaseVersion("0.103b")!,
            Stream64ReleaseVersion("0.103")!)
        XCTAssertEqual(
            Stream64ReleaseVersion("v0.103b"),
            Stream64ReleaseVersion("0.103b"))
    }

    func testUpdateAssetNamesMatchReleasePackaging() {
        let names = UpdateService.assetNames(
            tagName: "v0.103b", architecture: "arm64")
        XCTAssertEqual(names.archive, "Stream64-0.103b-macos-arm64.zip")
        XCTAssertEqual(
            names.checksum,
            "Stream64-0.103b-macos-arm64-SHA256.txt")
    }

    func testUpdateChecksumVerificationRejectsTampering() throws {
        let archive = Data("release archive".utf8)
        let digest = SHA256.hash(data: archive)
            .map { String(format: "%02x", $0) }
            .joined()
        let checksum = Data("\(digest)  Stream64-update.zip\n".utf8)
        XCTAssertNoThrow(try UpdateService.verifyChecksum(
            archiveData: archive,
            archiveName: "Stream64-update.zip",
            checksumData: checksum))
        XCTAssertThrowsError(try UpdateService.verifyChecksum(
            archiveData: Data("tampered".utf8),
            archiveName: "Stream64-update.zip",
            checksumData: checksum))
    }

    @MainActor
    func testUpdateServiceReportsAvailableStableRelease() async {
        let json = """
        {
          "tag_name": "v99.0b",
          "name": "Stream64 99.0b",
          "body": "Update notes",
          "html_url": "https://example.com/release",
          "draft": false,
          "prerelease": false,
          "assets": []
        }
        """
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = UpdateService(
            transport: StaticUpdateTransport(
                data: Data(json.utf8),
                statusCode: 200),
            defaults: defaults)
        service.check(force: true)
        for _ in 0..<10 { await Task.yield() }
        guard case .available(let release) = service.state else {
            return XCTFail("Expected an available stable release")
        }
        XCTAssertEqual(release.tagName, "v99.0b")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://example.com/release")
    }

    @MainActor
    func testUpdateServiceReportsMalformedGitHubResponse() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = UpdateService(
            transport: StaticUpdateTransport(
                data: Data("not-json".utf8),
                statusCode: 200),
            defaults: defaults)
        service.check(force: true)
        for _ in 0..<10 { await Task.yield() }
        guard case .failed = service.state else {
            return XCTFail("Expected malformed response to fail")
        }
    }

    @MainActor
    func testUpdateServiceSkipsAutomaticCheckWhenDisabled() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(false, forKey: "checkForUpdatesAutomatically")
        let service = UpdateService(
            transport: StaticUpdateTransport(
                data: Data("not-json".utf8),
                statusCode: 200),
            defaults: defaults)
        service.checkAutomatically()
        for _ in 0..<10 { await Task.yield() }
        guard case .idle = service.state else {
            return XCTFail("Automatic checking should be disabled")
        }
    }

    func testQueryQuotesTextAndCombinesAllFilters() {
        let filters = Assembly64SearchFilters(
            repository: "csdb",
            fileType: "d64",
            year: 1987,
            minimumRating: 7,
            latest: "1year",
            sort: "rating",
            order: "desc")
        let query = Assembly64SearchQuery(
            text: "last \"ninja\"",
            categoryName: "Games",
            filters: filters)

        XCTAssertTrue(query.hasConstraint)
        XCTAssertEqual(
            query.aql,
            "name:\"last ninja\" subcat:games repo:csdb type:d64 "
                + "date:1987 rating:>=7 latest:1year sort:rating order:desc")
    }

    func testFilterOnlyQueryIsAllowed() {
        var filters = Assembly64SearchFilters()
        filters.latest = "1month"
        filters.sort = "rating"
        filters.order = "desc"
        let query = Assembly64SearchQuery(
            text: "", categoryName: nil, filters: filters)

        XCTAssertTrue(query.hasConstraint)
        XCTAssertEqual(
            query.aql, "latest:1month sort:rating order:desc")
    }

    func testDefaultQueryHasNoConstraint() {
        let query = Assembly64SearchQuery(
            text: "  ", categoryName: nil,
            filters: Assembly64SearchFilters())
        XCTAssertFalse(query.hasConstraint)
    }

    func testSearchResultIdentityIncludesCategory() throws {
        let json = """
        {"id":"123","category":4,"name":"Demo"}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(
            Assembly64Client.SearchResult.self, from: json)

        XCTAssertEqual(result.itemID, "123")
        XCTAssertEqual(result.id, "4:123")
        XCTAssertEqual(result.libraryKey, "4:123")
    }

    func testSearchResultsTolerateMissingNamesAndSkipMissingIdentity() throws {
        let json = """
        [
          {"id":"106052","category":1,"group":"Beatless"},
          {"category":1,"name":"Missing ID"},
          {"id":"42","category":8,"name":"Assembler"}
        ]
        """.data(using: .utf8)!

        let results = try Assembly64Client.decodeSearchResults(json)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].name, "Beatless")
        XCTAssertEqual(results[0].id, "1:106052")
        XCTAssertEqual(results[1].name, "Assembler")
    }

    @MainActor
    func testLibraryStatePersistsFavoritesSearchesHistoryAndActions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try makeSearchResult(
            id: "123", category: 4, name: "Demo")
        let entry = Assembly64Client.FileEntry(
            id: 7, path: "Demo.d64", size: 174_848)
        var filters = Assembly64SearchFilters()
        filters.repository = "csdb"

        let store = Assembly64LibraryStore(storeURL: url)
        store.toggleFavorite(result)
        store.recordOpened(result)
        store.saveSearch(
            name: "CSDB demos", text: "demo",
            categoryID: 4, filters: filters)
        store.rememberAction(
            "mountAndRun", result: result, entry: entry)

        let reloaded = Assembly64LibraryStore(storeURL: url)
        XCTAssertTrue(reloaded.isFavorite(result))
        XCTAssertEqual(reloaded.recentResults, [result])
        XCTAssertEqual(reloaded.savedSearches.first?.name, "CSDB demos")
        XCTAssertEqual(
            reloaded.rememberedAction(result: result, entry: entry),
            "mountAndRun")
    }

    func testCSDBPreviewParsingAndURLValidation() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <CSDbData><Release>
          <ID>21937</ID>
          <ScreenShot>https://csdb.dk/gfx/releases/21000/21937.gif</ScreenShot>
        </Release></CSDbData>
        """.data(using: .utf8)!
        let preview = try CSDBPreviewClient.parse(
            data: xml, releaseID: "21937")

        XCTAssertEqual(
            preview.sourceURL.absoluteString,
            "https://csdb.dk/release/?id=21937")
        XCTAssertEqual(
            preview.imageURL?.absoluteString,
            "https://csdb.dk/gfx/releases/21000/21937.gif")
    }

    func testArchiveInspectionAndSelectiveExtraction() throws {
        let payload = Data([0x01, 0x08, 0x0B, 0x10])
        let data = try makeArchive([
            ("release/game.prg", payload, .file, .deflate),
            ("release/readme.txt", Data("notes".utf8), .file, .none),
        ])

        let items = try Assembly64ArchiveInspector.inspect(data)
        XCTAssertEqual(items.map(\.normalizedPath), [
            "release/game.prg", "release/readme.txt",
        ])
        XCTAssertTrue(items[0].isSupportedByDevice)
        XCTAssertFalse(items[1].isSupportedByDevice)
        XCTAssertEqual(
            try Assembly64ArchiveInspector.extract(items[0], from: data),
            payload)
    }

    func testArchiveRejectsTraversalPath() throws {
        let data = try makeArchive([
            ("../escape.prg", Data([1, 2, 3]), .file, .none),
        ])
        XCTAssertThrowsError(try Assembly64ArchiveInspector.inspect(data)) {
            XCTAssertEqual(
                $0 as? Assembly64ArchiveInspector.InspectionError,
                .unsafePath("../escape.prg"))
        }
    }

    func testArchiveRejectsSymlink() throws {
        let destination = Data("../outside".utf8)
        let data = try makeArchive([
            ("link", destination, .symlink, .none),
        ])
        XCTAssertThrowsError(try Assembly64ArchiveInspector.inspect(data)) {
            XCTAssertEqual(
                $0 as? Assembly64ArchiveInspector.InspectionError,
                .symbolicLink("link"))
        }
    }

    func testArchiveEnforcesEntryAndExpansionLimits() throws {
        let data = try makeArchive([
            ("one.prg", Data(repeating: 0, count: 64), .file, .deflate),
            ("two.prg", Data(repeating: 0, count: 64), .file, .deflate),
        ])
        var limits = Assembly64ArchiveInspector.Limits.default
        limits.maximumEntryCount = 1
        XCTAssertThrowsError(
            try Assembly64ArchiveInspector.inspect(data, limits: limits))

        limits = .default
        limits.maximumTotalUncompressedBytes = 100
        XCTAssertThrowsError(
            try Assembly64ArchiveInspector.inspect(data, limits: limits)) {
            XCTAssertEqual(
                $0 as? Assembly64ArchiveInspector.InspectionError,
                .totalSizeExceeded)
        }
    }

    func testSingleInstanceLockRejectsSecondOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")

        do {
            let first = SingleInstanceLock(lockURL: url)
            guard case .acquired = first.acquire() else {
                return XCTFail("First instance did not acquire lock")
            }

            let second = SingleInstanceLock(lockURL: url)
            guard case .alreadyRunning(let pid) = second.acquire() else {
                return XCTFail("Second instance unexpectedly acquired lock")
            }
            XCTAssertEqual(pid, getpid())
        }
    }

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

    func testFTPMLSDAndLISTParsing() throws {
        let endpoint = FileEndpoint.ultimate(UUID())
        let mlsd = Data("""
        type=dir;size=0;modify=20150904093646; carts\r
        type=file;size=174848;modify=20260722120000; game.d64\r
        """.utf8)
        let items = try UltimateFTPClient.parseMLSD(
            mlsd, endpoint: endpoint, parent: ManagedPath("/Flash"))
        XCTAssertEqual(items.map(\.name), ["carts", "game.d64"])
        XCTAssertEqual(items[0].kind, .directory)
        XCTAssertEqual(items[1].kind, .disk)
        XCTAssertEqual(items[1].size, 174_848)

        let listing = Data(
            "drw-rw-rw- 1 user ftp 0 Sep 04 2015 roms\r\n".utf8)
        let fallback = try UltimateFTPClient.parseLIST(
            listing, endpoint: endpoint, parent: ManagedPath("/Flash"))
        XCTAssertEqual(fallback.first?.name, "roms")
        XCTAssertEqual(fallback.first?.kind, .directory)
    }

    func testFTPCommandPathRejectsControlCharacters() {
        XCTAssertThrowsError(
            try UltimateFTPClient.commandPath(ManagedPath("/Flash/bad\nname")))
    }

    func testLiveUltimateFTPWhenConfigured() async throws {
        guard let host = ProcessInfo.processInfo.environment[
            "UV_LIVE_FTP_HOST"
        ] else {
            throw XCTSkip("Set UV_LIVE_FTP_HOST for live FTP validation")
        }
        let device = UltimateDevice(name: "FTP Test", host: host)
        let items = try await UltimateFTPClient(device: device).list(
            ManagedPath("/"))
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.contains { $0.isDirectory })
    }

    func testLiveUltimateFTPMutationsWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["UV_LIVE_FTP_HOST"],
              environment["UV_LIVE_FTP_MUTATIONS"] == "1" else {
            throw XCTSkip(
                "Set UV_LIVE_FTP_HOST and UV_LIVE_FTP_MUTATIONS=1")
        }
        let sourceDevice = UltimateDevice(name: "FTP Source", host: host)
        let destinationDevice = UltimateDevice(
            name: "FTP Destination", host: host)
        let client = UltimateFTPClient(device: sourceDevice)
        let folder = ManagedPath(
            "/Temp/Stream64-Test-\(UUID().uuidString)")
        let remote = folder.appending("probe.bin")
        let renamed = folder.appending("renamed.bin")
        let copied = folder.appending("c64-to-c64.bin")
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let downloaded = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let payload = Data("Stream64 FTP probe".utf8)
        try payload.write(to: local)
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: downloaded)
        }

        try await client.makeDirectory(folder)
        do {
            try await client.upload(local, to: remote) { _, _ in }
            let listing = try await client.list(folder)
            XCTAssertTrue(listing.contains {
                $0.name == "probe.bin"
            })
            try await client.download(remote, to: downloaded) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: downloaded), payload)
            try await client.rename(remote, to: renamed)
            let coordinator = FileOperationCoordinator { id in
                if id == sourceDevice.id { return sourceDevice }
                if id == destinationDevice.id { return destinationDevice }
                return nil
            }
            try await coordinator.process(TransferJob(operation: .copy(
                source: TransferReference(
                    endpoint: .ultimate(sourceDevice.id), path: renamed,
                    isDirectory: false, size: Int64(payload.count)),
                destination: TransferReference(
                    endpoint: .ultimate(destinationDevice.id), path: copied,
                    isDirectory: false, size: Int64(payload.count))
            ), conflictPolicy: .replace)) { _, _ in }
            let copiedListing = try await client.list(folder)
            XCTAssertTrue(copiedListing.contains {
                $0.name == copied.name
            })
            try await client.deleteFile(copied)
            try await client.deleteFile(renamed)
            try await client.deleteDirectory(folder)
        } catch {
            try? await client.deleteFile(remote)
            try? await client.deleteFile(renamed)
            try? await client.deleteFile(copied)
            try? await client.deleteDirectory(folder)
            throw error
        }
    }

    func testLocalProviderAndCoordinatorCopyMove() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.prg")
        try Data([1, 8, 0, 1]).write(to: source)
        let copy = root.appendingPathComponent("copy.prg")
        let moved = root.appendingPathComponent("moved.prg")
        let coordinator = FileOperationCoordinator { _ in nil }

        try await coordinator.process(TransferJob(operation: .copy(
            source: TransferReference(
                endpoint: .local, path: ManagedPath(source.path),
                isDirectory: false, size: 4),
            destination: TransferReference(
                endpoint: .local, path: ManagedPath(copy.path),
                isDirectory: false, size: 4)
        ), conflictPolicy: .replace)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: copy), Data([1, 8, 0, 1]))

        try await coordinator.process(TransferJob(operation: .move(
            source: TransferReference(
                endpoint: .local, path: ManagedPath(copy.path),
                isDirectory: false, size: 4),
            destination: TransferReference(
                endpoint: .local, path: ManagedPath(moved.path),
                isDirectory: false, size: 4)
        ))) { _, _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    func testMoveWithSkipPreservesSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.prg")
        let destination = root.appendingPathComponent("destination.prg")
        try Data("new source".utf8).write(to: source)
        try Data("existing destination".utf8).write(to: destination)
        let coordinator = FileOperationCoordinator { _ in nil }

        try await coordinator.process(
            TransferJob(
                operation: .move(
                    source: TransferReference(
                        endpoint: .local,
                        path: ManagedPath(source.path),
                        isDirectory: false,
                        size: 10),
                    destination: TransferReference(
                        endpoint: .local,
                        path: ManagedPath(destination.path),
                        isDirectory: false,
                        size: 20)),
                conflictPolicy: .skip)
        ) { _, _ in }

        XCTAssertEqual(
            try Data(contentsOf: source),
            Data("new source".utf8),
            "a skipped move must not delete its source")
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("existing destination".utf8),
            "Skip must not replace the existing destination")
    }

    func testLocalSymlinkTransfersAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        let link = root.appendingPathComponent("link.txt")
        try Data("secret target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target)

        let provider = LocalFileSystemProvider()
        let item = try await provider.item(ManagedPath(link.path))
        XCTAssertEqual(item?.kind, .symlink)

        let coordinator = FileOperationCoordinator { _ in nil }
        do {
            try await coordinator.process(
                TransferJob(
                    operation: .copy(
                        source: TransferReference(
                            endpoint: .local,
                            path: ManagedPath(link.path),
                            isDirectory: false,
                            size: nil),
                        destination: TransferReference(
                            endpoint: .local,
                            path: ManagedPath(
                                root.appendingPathComponent("copy.txt").path),
                            isDirectory: false,
                            size: nil)))
            ) { _, _ in }
            XCTFail("symbolic link transfer should be rejected")
        } catch {
            XCTAssertTrue(error is FileSystemError)
        }
    }

    @MainActor
    func testTransferQueuePersistsAndCompletesJobs() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: store) }
        let queue = TransferQueue(storeURL: store)
        queue.configure { _, progress in
            await progress(10, 10)
        }
        queue.enqueue(.makeDirectory(target: TransferReference(
            endpoint: .local, path: ManagedPath("/tmp/test"),
            isDirectory: true, size: nil)))
        for _ in 0..<100 where queue.jobs.first?.state != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(queue.jobs.first?.state, .completed)
        XCTAssertEqual(queue.jobs.first?.completedBytes, 10)

        let reloaded = TransferQueue(storeURL: store)
        XCTAssertEqual(reloaded.jobs.first?.state, .completed)
    }

    @MainActor
    func testTransferQueuePausesForConflictAndResumesWithChoice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.prg")
        let destinationURL = root.appendingPathComponent("destination.prg")
        try Data("new".utf8).write(to: sourceURL)
        try Data("old".utf8).write(to: destinationURL)
        let store = root.appendingPathComponent("queue.json")
        let coordinator = FileOperationCoordinator { _ in nil }
        let queue = TransferQueue(storeURL: store)
        queue.configure { job, progress in
            try await coordinator.process(job, progress: progress)
        }
        queue.enqueue(.copy(
            source: TransferReference(
                endpoint: .local, path: ManagedPath(sourceURL.path),
                isDirectory: false, size: 3),
            destination: TransferReference(
                endpoint: .local, path: ManagedPath(destinationURL.path),
                isDirectory: false, size: 3)),
            conflictPolicy: .ask)

        for _ in 0..<100 where queue.jobs.first?.state != .conflict {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(queue.jobs.first?.state, .conflict)
        queue.resolveConflict(queue.jobs[0].id, policy: .replace)
        for _ in 0..<100 where queue.jobs.first?.state != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(queue.jobs.first?.state, .completed)
        XCTAssertEqual(
            try Data(contentsOf: destinationURL), Data("new".utf8))
    }

    func testRemoteRunnerBuildsAuthenticatedPathRequest() async throws {
        let transport = RecordingHTTPTransport()
        let device = UltimateDevice(
            name: "Test", host: "192.168.1.64",
            password: "secret")
        let client = UltimateAPIClient(
            device: device, transport: transport)

        try await client.runPRG(path: "/Flash/My Game.prg")

        let recordedRequest = await transport.recordedRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/runners:run_prg")
        XCTAssertEqual(
            URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "file" })?.value,
            "/Flash/My Game.prg")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Password"), "secret")
    }

    func testMultipartFilenamesRejectHeaderInjectionAndPaths() {
        XCTAssertTrue(
            UltimateAPIClient.isSafeMultipartFilename("game.d64"))
        XCTAssertFalse(
            UltimateAPIClient.isSafeMultipartFilename("bad\"\r\nX-Evil: 1"))
        XCTAssertFalse(
            UltimateAPIClient.isSafeMultipartFilename("../game.d64"))
        XCTAssertFalse(
            UltimateAPIClient.isSafeMultipartFilename("folder/game.d64"))
        XCTAssertFalse(
            UltimateAPIClient.isSafeMultipartFilename("bad\\name.d64"))
    }

    func testAssemblyMetadataRejectsNonWebURLSchemes() {
        XCTAssertNotNil(
            Assembly64Client.validWebURL("https://example.com/image.png"))
        XCTAssertNotNil(
            Assembly64Client.validWebURL("http://example.com/image.png"))
        XCTAssertNil(Assembly64Client.validWebURL("file:///etc/passwd"))
        XCTAssertNil(Assembly64Client.validWebURL("data:text/plain,secret"))
        XCTAssertNil(Assembly64Client.validWebURL("javascript:alert(1)"))
        XCTAssertNil(Assembly64Client.validWebURL("custom://receiver/path"))
    }

    @MainActor
    func testAssemblyLibraryCorruptPersistenceIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("{invalid".utf8).write(to: storeURL)

        let store = Assembly64LibraryStore(storeURL: storeURL)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertNotNil(store.persistenceError)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains {
            $0.lastPathComponent.contains("corrupt-")
        })
    }

    @MainActor
    func testCommanderSpaceMarksAndAdvancesCursor() {
        let model = FilePaneModel(
            location: .local, path: ManagedPath("/tmp"))
        let first = FilesystemItem(
            endpoint: .local, path: ManagedPath("/tmp/one.prg"),
            kind: .prg, size: 1, modified: nil)
        let second = FilesystemItem(
            endpoint: .local, path: ManagedPath("/tmp/two.prg"),
            kind: .prg, size: 1, modified: nil)
        model.items = [first, second]
        model.selection = [first.id]

        model.toggleMarkAtCursor()

        XCTAssertEqual(model.markedIDs, [first.id])
        XCTAssertEqual(model.selection, [second.id])
        XCTAssertEqual(model.selectedItems, [first])

        model.toggleMark(second.id)
        XCTAssertEqual(model.markedIDs, [first.id, second.id])
        model.toggleMark(first.id)
        XCTAssertEqual(model.markedIDs, [second.id])
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

    func testMenuScreenDecodingAndRequest() async throws {
        let transport = MenuScreenHTTPTransport()
        let client = UltimateAPIClient(
            device: UltimateDevice(
                name: "Menu", host: "192.168.1.64"),
            transport: transport)
        let screen = try await client.fetchMenuScreen()

        XCTAssertEqual(screen.characters.count, 1000)
        XCTAssertEqual(screen.colors.count, 1000)
        XCTAssertEqual(screen.character(at: 0, row: 0), 1)
        XCTAssertEqual(screen.color(at: 0, row: 0), 0x16)
        XCTAssertEqual(UltimateMenuGlyph.character(0x42), "B")
        XCTAssertEqual(UltimateMenuGlyph.character(0x00), " ")
        XCTAssertEqual(UltimateMenuGlyph.character(0x01), "┌")
        XCTAssertEqual(UltimateMenuGlyph.character(0x82), "─")
        let request = await transport.lastRequest
        XCTAssertEqual(
            request?.url?.path,
            "/v1/machine:menu_screen")
    }

    func testLiveMenuScreenCapabilityWhenConfigured() async throws {
        guard let host = ProcessInfo.processInfo.environment[
            "UV_LIVE_MENU_HOST"
        ] else {
            throw XCTSkip("Set UV_LIVE_MENU_HOST for live menu probing")
        }
        let client = UltimateAPIClient(
            device: UltimateDevice(name: "Menu Probe", host: host))
        try await client.menuButton()
        defer { Task { try? await client.menuButton() } }
        try await Task.sleep(for: .milliseconds(250))
        do {
            let screen = try await client.fetchMenuScreen()
            XCTAssertEqual(screen.characters.count, 1000)
        } catch UltimateAPIClient.APIError.httpError(let code, _) {
            XCTAssertEqual(code, 404)
        }
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

        // Fill ignores aspect; Fit and Integer-with-fallback agree on a
        // small window where integer would look tiny.
        let tiny = CGSize(width: 640, height: 400)
        let fit = VideoScaling.scaleFactors(mode: .aspectFit, drawableSize: tiny)
        let smartInteger = VideoScaling.scaleFactors(
            mode: .integer, drawableSize: tiny)
        XCTAssertEqual(fit.x, smartInteger.x, accuracy: 0.0001)
        XCTAssertEqual(fit.y, smartInteger.y, accuracy: 0.0001)
    }

    func testViewerPaneDroppableExtensionsIncludeSIDAndCRT() {
        XCTAssertTrue(ViewerPane.droppableExtensions.contains("sid"))
        XCTAssertTrue(ViewerPane.droppableExtensions.contains("crt"))
        XCTAssertTrue(ViewerPane.droppableExtensions.contains("prg"))
        XCTAssertTrue(ViewerPane.droppableExtensions.contains("d64"))
    }

    func testSIDEngineAdaptiveTickAndSampleCap() {
        XCTAssertEqual(
            SIDEngine.effectiveTickInterval(subscriberCount: 1),
            1.0 / 30.0,
            accuracy: 0.0001)
        XCTAssertEqual(
            SIDEngine.effectiveTickInterval(subscriberCount: 6),
            1.0 / 15.0,
            accuracy: 0.0001)
        XCTAssertEqual(
            SIDEngine.effectiveTickInterval(subscriberCount: 12),
            1.0 / 10.0,
            accuracy: 0.0001)
        XCTAssertEqual(
            SIDEngine.effectiveTickInterval(
                subscriberCount: 1, videoDisplayBehind: true),
            1.0 / 12.0,
            accuracy: 0.0001)
        XCTAssertEqual(
            SIDEngine.synthesisSampleCap(subscriberCount: 1, requested: 267),
            267)
        XCTAssertEqual(
            SIDEngine.synthesisSampleCap(subscriberCount: 6, requested: 267),
            133)
        XCTAssertEqual(
            SIDEngine.synthesisSampleCap(subscriberCount: 12, requested: 267),
            66)
        XCTAssertEqual(
            SIDEngine.synthesisSampleCap(
                subscriberCount: 1, requested: 267, videoDisplayBehind: true),
            66)
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

    func testSIDEngineAudioMailboxDropsOldestWhenCapped() {
        var pending: [Float] = Array(repeating: 1, count: 8)
        SIDEngine.appendCappedAudioSamples(
            &pending,
            Array(repeating: 2, count: 6),
            maxCount: 10)
        XCTAssertEqual(pending.count, 10)
        XCTAssertEqual(pending.first, 1)
        XCTAssertEqual(pending.last, 2)
        // Four of the original ones should remain, then six new samples.
        XCTAssertEqual(pending.filter { $0 == 1 }.count, 4)
        XCTAssertEqual(pending.filter { $0 == 2 }.count, 6)
        XCTAssertEqual(SIDEngine.maxPendingAudioSamples, 10_000)
    }

    func testDebugStreamPacketParsingToleratesShortPacket() {
        let (sequence, entries) = DebugStreamEntry.parsePacket(Data([0x01]), source: .vic)
        XCTAssertEqual(sequence, 0)
        XCTAssertTrue(entries.isEmpty)
    }

    func testVT100ScreenHandlesCursorPositioningAndText() {
        let screen = VT100Screen(columns: 10, rows: 3)
        screen.feed(Data("\u{1B}[2;3HHi".utf8))
        XCTAssertEqual(screen.cell(atColumn: 2, row: 1).character, "H")
        XCTAssertEqual(screen.cell(atColumn: 3, row: 1).character, "i")
        XCTAssertEqual(screen.cursorRow, 1)
        XCTAssertEqual(screen.cursorColumn, 4)
    }

    func testVT100ScreenErasesDisplayAndAppliesSGRColors() {
        let screen = VT100Screen(columns: 5, rows: 2)
        screen.feed(Data("ABCDE".utf8))
        screen.feed(Data("\u{1B}[2J".utf8))
        XCTAssertEqual(screen.cell(atColumn: 0, row: 0).character, " ")

        // ED does not move the cursor — reposition explicitly before
        // writing, rather than relying on where "ABCDE" happened to wrap.
        screen.feed(Data("\u{1B}[1;1H\u{1B}[31mX".utf8))
        XCTAssertEqual(screen.cell(atColumn: 0, row: 0).character, "X")
        XCTAssertEqual(screen.cell(atColumn: 0, row: 0).foreground, 1)

        screen.feed(Data("\u{1B}[0mY".utf8))
        XCTAssertEqual(screen.cell(atColumn: 1, row: 0).foreground, 7)
    }

    func testVT100ScreenWrapsAndScrollsOnOverflow() {
        let screen = VT100Screen(columns: 3, rows: 2)
        screen.feed(Data("ABCDEF".utf8))
        XCTAssertEqual(screen.cell(atColumn: 0, row: 0).character, "D")
        XCTAssertEqual(screen.cell(atColumn: 2, row: 0).character, "F")
        XCTAssertEqual(screen.cell(atColumn: 0, row: 1).character, " ")

        screen.feed(Data("GHI".utf8))
        XCTAssertEqual(screen.cell(atColumn: 0, row: 0).character, "G")
        XCTAssertEqual(screen.cell(atColumn: 2, row: 0).character, "I")
    }

    func testVT100ScreenHandlesCarriageReturnAndLineFeedIndependently() {
        let screen = VT100Screen(columns: 5, rows: 2)
        screen.feed(Data("AB\r\nCD".utf8))
        XCTAssertEqual(screen.cell(atColumn: 0, row: 0).character, "A")
        XCTAssertEqual(screen.cell(atColumn: 1, row: 0).character, "B")
        XCTAssertEqual(screen.cell(atColumn: 0, row: 1).character, "C")
        XCTAssertEqual(screen.cell(atColumn: 1, row: 1).character, "D")
    }

    func testVT100ScreenPassesPlainASCIIThroughUnchangedIncludingLowercase() {
        // Confirmed against a real device: the Ultimate's Telnet UI sends
        // genuine mixed-case ASCII text ("Ultimate", "Free", etc.), not
        // the C64's internal PETSCII *screen* encoding (where this same
        // byte range means graphics/uppercase-only). A prior version of
        // this decoder assumed the latter and turned ordinary lowercase
        // letters into PETSCII graphics — e.g. 'a' into "♠" — which badly
        // regressed real-world text. The entire printable range must
        // therefore pass through completely unchanged.
        let screen = VT100Screen(columns: 20, rows: 1)
        screen.feed(Data("Ultimate 64-II \\^_".utf8))
        let text = String((0..<18).map { screen.cell(atColumn: $0, row: 0).character })
        XCTAssertEqual(text, "Ultimate 64-II \\^_")
    }

    func testTelnetIACFilterStripsNegotiationSequencesFromRealDeviceCapture() {
        // The exact byte-for-byte preamble a real device sends
        // immediately on connect (captured live): IAC DONT LINEMODE,
        // IAC WILL ECHO, then genuine VT100 content. Unfiltered, this
        // leaked 5 stray characters into the very start of the screen.
        let filter = TelnetIACFilter()
        let raw = Data([0xFF, 0xFE, 0x22, 0xFF, 0xFB, 0x01]) + Data("*** Ultimate 64-II ***".utf8)
        let filtered = filter.filter(raw)
        XCTAssertEqual(filtered, Data("*** Ultimate 64-II ***".utf8))
    }

    func testTelnetIACFilterHandlesSubnegotiationAndEscapedLiteralFF() {
        let filter = TelnetIACFilter()
        // IAC SB <anything, including a stray non-SE byte> IAC SE, then
        // IAC IAC (a literal 0xFF byte), then plain text.
        let raw = Data([0xFF, 0xFA, 0x18, 0x01, 0xFF, 0xF0, 0xFF, 0xFF]) + Data("AB".utf8)
        let filtered = filter.filter(raw)
        XCTAssertEqual(filtered, Data([0xFF]) + Data("AB".utf8))
    }

    func testTelnetIACFilterHandlesSequenceSplitAcrossTwoChunks() {
        // A real TCP read boundary could land anywhere inside a
        // multi-byte IAC sequence — the filter must carry state across
        // separate `filter(_:)` calls, not just within a single one.
        let filter = TelnetIACFilter()
        let first = filter.filter(Data([0xFF, 0xFB])) // IAC WILL, option byte not here yet
        let second = filter.filter(Data([0x01]) + Data("X".utf8)) // option byte, then text
        XCTAssertEqual(first, Data())
        XCTAssertEqual(second, Data("X".utf8))
    }

    func testVT100ScreenHandlesDECPrivateModeSequencesWithoutLeakingText() {
        // ESC[?25l (hide cursor) and ESC[?1049h (alternate screen
        // buffer) are common, standard sequences some firmware toggles
        // on every cursor blink. A parser that treats '?' as if it were
        // the CSI sequence's final byte would end the sequence early and
        // write the leftover "25l"/"1049h" onto the screen as literal
        // text — repeated often enough (e.g. every blink), this
        // compounds into a garbled or fully scrolled-past-blank screen.
        let screen = VT100Screen(columns: 10, rows: 3)
        screen.feed(Data("\u{1B}[?25l\u{1B}[?1049hAB".utf8))
        XCTAssertEqual(screen.cell(atColumn: 0, row: 0).character, "A")
        XCTAssertEqual(screen.cell(atColumn: 1, row: 0).character, "B")
        XCTAssertEqual(screen.cursorColumn, 2)
        XCTAssertEqual(screen.cursorRow, 0)

        // A real cursor-position sequence right after a DEC private-mode
        // one must still work — confirms the parser returned to normal
        // CSI handling, not some stuck state.
        screen.feed(Data("\u{1B}[2;3H\u{1B}[?25hC".utf8))
        XCTAssertEqual(screen.cell(atColumn: 2, row: 1).character, "C")
    }

    func testVT100ScreenDecodesDECSpecialGraphicsLineDrawing() {
        // Reproduces exactly what a real device's Telnet menu sends for a
        // bordered box: ESC ) 0 designates G1 as the line-drawing set,
        // SO (0x0E) shifts to it so plain lowercase letters ('q', which
        // is just "q" as normal text) become box-drawing glyphs, and SI
        // (0x0F) shifts back to G0 (still plain ASCII, never designated
        // otherwise) for normal text afterwards.
        let screen = VT100Screen(columns: 20, rows: 3)
        screen.feed(Data([0x1B, UInt8(ascii: ")"), UInt8(ascii: "0")])) // ESC ) 0
        screen.feed(Data([0x0E])) // SO
        screen.feed(Data("lqqqk".utf8))
        screen.feed(Data([0x0F])) // SI
        screen.feed(Data("SD".utf8))

        XCTAssertEqual(screen.cell(atColumn: 0, row: 0).character, "┌")
        XCTAssertEqual(screen.cell(atColumn: 1, row: 0).character, "─")
        XCTAssertEqual(screen.cell(atColumn: 2, row: 0).character, "─")
        XCTAssertEqual(screen.cell(atColumn: 3, row: 0).character, "─")
        XCTAssertEqual(screen.cell(atColumn: 4, row: 0).character, "┐")
        // After SI, plain text resumes unaffected — same bytes that were
        // just remapped as graphics render as ordinary letters again.
        XCTAssertEqual(screen.cell(atColumn: 5, row: 0).character, "S")
        XCTAssertEqual(screen.cell(atColumn: 6, row: 0).character, "D")
    }

    func testVT100ScreenDecodesHighByteGraphicsAndControlCodes() {
        let screen = VT100Screen(columns: 10, rows: 2)

        // Bytes with no legitimate meaning as plain ASCII (0x80-0xFF) are
        // still decoded as PETSCII-style decorative graphics/controls,
        // since the on-device menu's borders/meters do appear to use
        // that range and doing so can never corrupt real text.
        screen.feed(Data([0xC9, 0xCA, 0xCB])) // rounded box corners
        XCTAssertEqual(screen.cell(atColumn: 0, row: 0).character, "╮")
        XCTAssertEqual(screen.cell(atColumn: 1, row: 0).character, "╰")
        XCTAssertEqual(screen.cell(atColumn: 2, row: 0).character, "╯")

        // Raw PETSCII color/cursor control codes (not wrapped in a VT100
        // CSI sequence) move the cursor / change color instead of being
        // written into a cell as a stray character.
        screen.feed(Data([0x1C])) // RED
        screen.feed(Data([0x51])) // 'Q'
        XCTAssertEqual(screen.cell(atColumn: 3, row: 0).character, "Q")
        XCTAssertEqual(screen.cell(atColumn: 3, row: 0).foreground, 1)

        screen.feed(Data([0x0D])) // CR, back to column 0
        screen.feed(Data([0x11])) // CURSOR DOWN (raw PETSCII, not CSI)
        XCTAssertEqual(screen.cursorRow, 1)
        XCTAssertEqual(screen.cursorColumn, 0)
    }

    func testSIDVoiceRegistersDecodeFrequencyPulseWidthAndControlBits() {
        var registers = SIDVoiceRegisters()
        registers.write(offset: 0, value: 0x34) // freq lo
        registers.write(offset: 1, value: 0x12) // freq hi
        registers.write(offset: 2, value: 0xAB) // pulse width lo
        registers.write(offset: 3, value: 0xFF) // pulse width hi (masked to 4 bits)
        let gate: UInt8 = 0x01, triangle: UInt8 = 0x10, pulse: UInt8 = 0x40, noise: UInt8 = 0x80
        registers.write(offset: 4, value: gate | triangle | pulse | noise)
        registers.write(offset: 5, value: 0x9A) // attack=9, decay=A
        registers.write(offset: 6, value: 0x5C) // sustain=5, release=C

        XCTAssertEqual(registers.frequency, 0x1234)
        XCTAssertEqual(registers.pulseWidth, 0x0FAB)
        XCTAssertTrue(registers.gate)
        XCTAssertFalse(registers.syncEnabled)
        XCTAssertFalse(registers.ringModEnabled)
        XCTAssertFalse(registers.test)
        XCTAssertTrue(registers.triangleEnabled)
        XCTAssertFalse(registers.sawtoothEnabled)
        XCTAssertTrue(registers.pulseEnabled)
        XCTAssertTrue(registers.noiseEnabled)
        XCTAssertEqual(registers.attack, 9)
        XCTAssertEqual(registers.decay, 0xA)
        XCTAssertEqual(registers.sustain, 5)
        XCTAssertEqual(registers.release, 0xC)
    }

    func testSIDVoiceSynthTriangleReachesFullRangeAfterAttack() {
        var registers = SIDVoiceRegisters()
        registers.write(offset: 1, value: 0x10) // frequency = 0x1000 (~240 Hz)
        registers.write(offset: 4, value: 0x11) // gate + triangle
        registers.write(offset: 5, value: 0x00) // fastest attack/decay
        registers.write(offset: 6, value: 0xF0) // full sustain, fastest release

        var synth = SIDVoiceSynth()
        let dt = 1.0 / SIDVoiceSynth.clockHz
        let totalSteps = Int(0.05 / dt)
        var minValue = 1.0, maxValue = -1.0
        for step in 0..<totalSteps {
            let sample = synth.step(dt: dt, registers: registers, neighborPhase: 0)
            if step > totalSteps / 2 { // only once envelope/oscillator have settled
                minValue = min(minValue, sample)
                maxValue = max(maxValue, sample)
            }
        }
        XCTAssertGreaterThan(maxValue, 0.9)
        XCTAssertLessThan(minValue, -0.9)
    }

    func testSIDVoiceSynthEnvelopeReleasesTowardZeroWhenGateClears() {
        var registers = SIDVoiceRegisters()
        registers.write(offset: 1, value: 0x10)
        registers.write(offset: 4, value: 0x11) // gate + triangle
        registers.write(offset: 5, value: 0x00) // fastest attack/decay
        registers.write(offset: 6, value: 0xF0) // full sustain, fastest release

        var synth = SIDVoiceSynth()
        let dt = 1.0 / SIDVoiceSynth.clockHz
        for _ in 0..<Int(0.02 / dt) {
            _ = synth.step(dt: dt, registers: registers, neighborPhase: 0)
        }
        XCTAssertGreaterThan(synth.envelope, 0.9) // fully attacked into sustain

        registers.write(offset: 4, value: 0x10) // clear gate, keep triangle selected
        for _ in 0..<Int(0.05 / dt) {
            _ = synth.step(dt: dt, registers: registers, neighborPhase: 0)
        }
        XCTAssertLessThan(synth.envelope, 0.1)
    }

    func testSIDVoiceSynthPulseRespectsPulseWidth() {
        var registers = SIDVoiceRegisters()
        registers.write(offset: 1, value: 0x08) // frequency = 0x0800 (~120 Hz)
        registers.write(offset: 2, value: 0x00)
        registers.write(offset: 3, value: 0x02) // pulse width = 0x200 → duty ≈ 12.5%
        registers.write(offset: 4, value: 0x41) // gate + pulse
        registers.write(offset: 5, value: 0x00)
        registers.write(offset: 6, value: 0xF0) // full sustain

        var synth = SIDVoiceSynth()
        let dt = 1.0 / SIDVoiceSynth.clockHz
        for _ in 0..<Int(0.01 / dt) { // let the envelope settle first
            _ = synth.step(dt: dt, registers: registers, neighborPhase: 0)
        }

        var highCount = 0
        var total = 0
        for _ in 0..<Int(0.2 / dt) { // ~24 periods, enough to average out edge effects
            let sample = synth.step(dt: dt, registers: registers, neighborPhase: 0)
            total += 1
            if sample > 0 { highCount += 1 }
        }
        let ratio = Double(highCount) / Double(total)
        XCTAssertEqual(ratio, 512.0 / 4095.0, accuracy: 0.02)
    }

    func testSIDSpectrumAnalyzerPeaksAtInputSineFrequency() throws {
        let sampleRate = 48000.0
        let analyzer = SIDSpectrumAnalyzer(sampleRate: sampleRate)
        let toneHz = 2000.0

        // Feed enough sine samples for several FFT frames so the window
        // has settled; keep the last non-nil bar spectrum.
        var lastBars: [Float]?
        var phase = 0.0
        let totalSamples = SIDSpectrumAnalyzer.fftSize * 4
        var samples = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            samples[i] = Float(sin(phase))
            phase += 2 * Double.pi * toneHz / sampleRate
        }
        // Feed in FFT-sized chunks, same as a real caller would.
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 256, samples.count)
            if let bars = analyzer.ingest(Array(samples[offset..<end])) {
                lastBars = bars
            }
            offset = end
        }

        let bars = try XCTUnwrap(lastBars)
        XCTAssertEqual(bars.count, SIDSpectrumAnalyzer.barCount)

        // The loudest bar should be one whose log-spaced frequency range
        // covers (or is very close to) 2 kHz.
        let peakIndex = bars.indices.max(by: { bars[$0] < bars[$1] })!
        let nyquist = sampleRate / 2
        let minFrequency = 40.0
        let peakBarFrequency = minFrequency * pow(nyquist / minFrequency, Double(peakIndex) / Double(bars.count))
        XCTAssertEqual(peakBarFrequency, toneHz, accuracy: toneHz * 0.5)
    }

    func testSIDFilterRegistersDecodeCutoffResonanceRoutingAndMode() {
        var filter = SIDFilterRegisters()
        filter.write(offset: 0, value: 0x05) // cutoff lo (3 bits used)
        filter.write(offset: 1, value: 0x3C) // cutoff hi
        let resonance: UInt8 = 0x90 // resonance=9, voice1+voice2 routed
        filter.write(offset: 2, value: resonance | 0x03)
        let mode: UInt8 = 0x0A | 0x10 // volume=10, low-pass enabled
        filter.write(offset: 3, value: mode)

        XCTAssertEqual(filter.cutoffValue, (0x3C << 3) | 0x05)
        XCTAssertEqual(filter.resonance, 9)
        XCTAssertTrue(filter.voiceRouted(0))
        XCTAssertTrue(filter.voiceRouted(1))
        XCTAssertFalse(filter.voiceRouted(2))
        XCTAssertFalse(filter.externalRouted)
        XCTAssertEqual(filter.volume, 10)
        XCTAssertTrue(filter.lowPassEnabled)
        XCTAssertFalse(filter.bandPassEnabled)
        XCTAssertFalse(filter.highPassEnabled)
        XCTAssertFalse(filter.voice3Disconnected)

        // Cutoff-to-Hz is a monotonic approximation, not a specific value.
        XCTAssertLessThan(
            SIDFilterRegisters.approximateCutoffHz(0),
            SIDFilterRegisters.approximateCutoffHz(2047))
    }

    @MainActor
    func testSIDVoiceChannelNoteHistoryRecordsGateAndFrequencyOverTime() {
        var channel = SIDVoiceChannel(
            id: 0, chipIndex: 0, voiceIndex: 0, bufferSize: 8, noteHistoryLength: 4)
        channel.registers.write(offset: 0, value: 0x00)
        channel.registers.write(offset: 1, value: 0x10) // some frequency
        channel.registers.write(offset: 4, value: 0x01) // gate on

        channel.pushNoteHistory()
        channel.registers.write(offset: 4, value: 0x00) // gate off
        channel.pushNoteHistory()

        let history = channel.orderedNoteHistory
        XCTAssertEqual(history.count, 4) // fixed ring-buffer size
        // Most recent two entries (end of the chronological array) are the
        // ones just pushed: gate-on then gate-off, same frequency.
        XCTAssertTrue(history[2].gate)
        XCTAssertFalse(history[3].gate)
        XCTAssertEqual(history[2].frequencyHz, history[3].frequencyHz, accuracy: 0.01)
    }

    func testSIDVoiceChannelResetToSilenceClearsAllReconstructedState() {
        var channel = SIDVoiceChannel(
            id: 0, chipIndex: 0, voiceIndex: 0, bufferSize: 8, noteHistoryLength: 4)
        channel.registers.write(offset: 0, value: 0x34) // frequency lo
        channel.registers.write(offset: 1, value: 0x12) // frequency hi
        channel.registers.write(offset: 4, value: 0x11) // gate on, triangle
        channel.push(sample: 0.8, envelope: 0.9)
        channel.pushNoteHistory()

        XCTAssertNotEqual(channel.registers, SIDVoiceRegisters())
        XCTAssertGreaterThan(channel.peakLevel, 0)
        XCTAssertTrue(channel.orderedSamples.contains { $0 != 0 })

        channel.resetToSilence()

        XCTAssertEqual(channel.registers, SIDVoiceRegisters())
        XCTAssertEqual(channel.peakLevel, 0)
        XCTAssertTrue(channel.orderedSamples.allSatisfy { $0 == 0 })
        XCTAssertTrue(channel.orderedEnvelopeSamples.allSatisfy { $0 == 0 })
        XCTAssertTrue(channel.orderedNoteHistory.allSatisfy { !$0.gate })
        XCTAssertFalse(channel.registers.gate)
        XCTAssertEqual(channel.frequencyHz, 0)
    }

    func testSIDVoiceChannelPeakLevelHoldsThenDecays() {
        var channel = SIDVoiceChannel(
            id: 0, chipIndex: 0, voiceIndex: 0, bufferSize: 8, noteHistoryLength: 4)
        XCTAssertEqual(channel.peakLevel, 0)

        channel.push(sample: 0.9, envelope: 1)
        XCTAssertEqual(channel.peakLevel, 0.9, accuracy: 0.001)

        // A much quieter sample right after should not immediately drop
        // the peak to that quiet level — peak-hold decays slowly rather
        // than tracking instantaneously like the RMS-based level does.
        channel.push(sample: 0.05, envelope: 1)
        XCTAssertGreaterThan(channel.peakLevel, 0.5)

        // Enough further silence should let it decay meaningfully.
        for _ in 0..<2000 {
            channel.push(sample: 0, envelope: 1)
        }
        XCTAssertLessThan(channel.peakLevel, 0.5)
    }

    func testSIDVisualizationModeNeedsSampleSynthesisOnlyForWaveformDrivenModes() {
        // The audio-rate oscillator/envelope stepping loop in `tick()` is
        // by far the most expensive part of a window's update cycle — only
        // the modes that actually read its output (waveform samples, RMS
        // level, or peak-hold level) should require it.
        let waveformDriven: Set<SIDVisualizationMode> = [
            .oscilloscope, .envelope, .mixerConsole, .vuMeterBank, .colorfulWaveform,
        ]
        for mode in SIDVisualizationMode.allCases {
            XCTAssertEqual(
                mode.needsSampleSynthesis, waveformDriven.contains(mode),
                "\(mode.rawValue) needsSampleSynthesis mismatch")
        }
    }

    func testSIDVisualizationModeNeedsRegisterWritesIsInverseOfAudioTap() {
        // No mode currently needs both the debug bus-trace (register
        // writes) and the raw post-mix audio tap — every mode is one or
        // the other. `needsRegisterWrites` exists as a positively-phrased
        // name for that same split, so this locks in the assumption that
        // lets `start()` treat them as mutually exclusive gates.
        for mode in SIDVisualizationMode.allCases {
            XCTAssertEqual(mode.needsRegisterWrites, !mode.needsAudioTap, "\(mode.rawValue) mismatch")
        }
        // Spot-check both directions explicitly rather than only the
        // derived relationship above.
        XCTAssertTrue(SIDVisualizationMode.oscilloscope.needsRegisterWrites)
        XCTAssertFalse(SIDVisualizationMode.spectrum.needsRegisterWrites)
    }

    func testSIDEngineNeedsMatchesModeFlagsForAllVisualizationModes() {
        for mode in SIDVisualizationMode.allCases {
            let needs = SIDEngineNeeds(mode: mode)
            XCTAssertEqual(needs.needsRegisterWrites, mode.needsRegisterWrites, "\(mode.rawValue)")
            XCTAssertEqual(needs.needsSampleSynthesis, mode.needsSampleSynthesis, "\(mode.rawValue)")
            XCTAssertEqual(needs.needsAudioTap, mode.needsAudioTap, "\(mode.rawValue)")
            XCTAssertEqual(needs.usesSpectrumBars, mode.usesSpectrumBars, "\(mode.rawValue)")
            XCTAssertEqual(needs.usesSpectrogramHistory, mode.usesSpectrogramHistory, "\(mode.rawValue)")
            // Lissajous is the one audio-tap mode that plots raw points
            // rather than FFT bars, so it's the only mode this should be
            // true for.
            XCTAssertEqual(needs.needsLissajousPoints, mode == .lissajous, "\(mode.rawValue)")
        }
    }

    func testSIDEngineNeedsUnionIsTrueIfEitherSideNeedsIt() {
        // Oscilloscope needs register writes + sample synthesis; Spectrum
        // Analyzer needs the audio tap + spectrum bars instead — two
        // subscribers with non-overlapping needs should aggregate to the
        // union of both, not just one or the other.
        let oscilloscope = SIDEngineNeeds(mode: .oscilloscope)
        let spectrum = SIDEngineNeeds(mode: .spectrum)
        let union = oscilloscope.union(spectrum)

        XCTAssertTrue(union.needsRegisterWrites)
        XCTAssertTrue(union.needsSampleSynthesis)
        XCTAssertTrue(union.needsAudioTap)
        XCTAssertTrue(union.usesSpectrumBars)
        // Neither side needs these, so the union shouldn't either.
        XCTAssertFalse(union.usesSpectrogramHistory)
        XCTAssertFalse(union.needsLissajousPoints)
    }

    @MainActor
    func testSIDEngineSharedReturnsSameInstanceUntilLastSubscriberLeaves() {
        let session = DeviceSession(
            device: UltimateDevice(name: "SIDEngine Test", host: "192.0.2.1"),
            settings: AppSettings())

        let engineA = SIDEngine.shared(for: session)
        let tokenA = engineA.subscribe(needs: SIDEngineNeeds(mode: .registerActivity)) {}

        // A second subscribe for the same device must reuse the same
        // engine instance, not create a competing one.
        let engineB = SIDEngine.shared(for: session)
        XCTAssertTrue(engineA === engineB)
        let tokenB = engineB.subscribe(needs: SIDEngineNeeds(mode: .adsrKnobs)) {}

        engineA.unsubscribe(tokenA)
        // One of two subscribers left — the engine must still be alive
        // and still be the one `shared(for:)` returns.
        let engineC = SIDEngine.shared(for: session)
        XCTAssertTrue(engineB === engineC)

        engineB.unsubscribe(tokenB)
        // The *last* subscriber just left — the engine should have torn
        // itself down and removed itself from the shared registry, so
        // this call constructs a brand-new instance rather than
        // resurrecting the stopped one.
        let engineD = SIDEngine.shared(for: session)
        XCTAssertFalse(engineC === engineD)
    }

    @MainActor
    func testSIDEngineSupportsSubscribersWithDifferentNeedsSimultaneously() {
        // One subscriber needs only register writes (no synthesis, no
        // audio tap); another needs only the audio tap. Neither should
        // interfere with the other being able to subscribe/unsubscribe
        // independently.
        let session = DeviceSession(
            device: UltimateDevice(name: "SIDEngine Mixed Needs Test", host: "192.0.2.1"),
            settings: AppSettings())
        let engine = SIDEngine.shared(for: session)

        let registerToken = engine.subscribe(needs: SIDEngineNeeds(mode: .registerActivity)) {}
        let audioToken = engine.subscribe(needs: SIDEngineNeeds(mode: .spectrum)) {}

        engine.unsubscribe(registerToken)
        // The audio-tap subscriber is still active, so the engine must
        // not have torn itself down yet.
        XCTAssertTrue(SIDEngine.shared(for: session) === engine)

        engine.unsubscribe(audioToken)
        XCTAssertFalse(SIDEngine.shared(for: session) === engine)
    }

    func testSIDRegisterActivityRecordsWritesPerChipAndOffset() {
        var activity = SIDRegisterActivity(chipCount: 2)
        XCTAssertEqual(activity.lastWrite.count, 2)
        XCTAssertEqual(activity.lastWrite[0].count, SIDRegisterActivity.registerCount)
        XCTAssertTrue(activity.lastWrite[0].allSatisfy { $0 == nil })

        let now = Date()
        activity.record(chipIndex: 0, offset: 4, at: now) // V1 CTRL
        activity.record(chipIndex: 1, offset: 22, at: now) // RES/FILT

        XCTAssertEqual(activity.lastWrite[0][4], now)
        XCTAssertNil(activity.lastWrite[0][22])
        XCTAssertEqual(activity.lastWrite[1][22], now)

        // Out-of-range chip/offset are ignored rather than crashing.
        activity.record(chipIndex: 5, offset: 0, at: now)
        activity.record(chipIndex: 0, offset: 99, at: now)
    }

    func testSIDRegisterActivityMnemonicsCoverAllRegistersInOrder() {
        XCTAssertEqual(SIDRegisterActivity.mnemonics.count, SIDRegisterActivity.registerCount)
        XCTAssertEqual(SIDRegisterActivity.mnemonics.first, "V1 FREQ LO")
        XCTAssertEqual(SIDRegisterActivity.mnemonics[6], "V1 SR")
        XCTAssertEqual(SIDRegisterActivity.mnemonics[7], "V2 FREQ LO")
        XCTAssertEqual(SIDRegisterActivity.mnemonics.last, "MODE/VOL")
    }

    func testSIDVoiceLineupDetectsOnsetsOnGateAndPitchSlide() {
        var channel = SIDVoiceChannel(
            id: 0, chipIndex: 0, voiceIndex: 0, bufferSize: 8, noteHistoryLength: 6)

        func push(frequency: UInt16, gate: Bool) {
            channel.registers.write(offset: 0, value: UInt8(frequency & 0xFF))
            channel.registers.write(offset: 1, value: UInt8(frequency >> 8))
            channel.registers.write(offset: 4, value: gate ? 0x01 : 0x00)
            channel.pushNoteHistory()
        }

        push(frequency: 0x1000, gate: false) // index 0: silence, no onset
        push(frequency: 0x1000, gate: true)  // index 1: gate-on onset
        push(frequency: 0x1000, gate: true)  // index 2: same note held, no onset
        push(frequency: 0x1400, gate: true)  // index 3: slid to a clearly different pitch, onset
        push(frequency: 0x1400, gate: false) // index 4: gate off, no onset
        push(frequency: 0x1400, gate: false) // index 5: still off, no onset

        let onsets = SIDVoiceLineupView.onsets(for: channel)
        XCTAssertEqual(onsets.map(\.index), [1, 3])
    }

    func testSIDOscilloscopeGridLayoutPrefersFewerRowsOnWideScreens() {
        // 11 modes, wide screen: should fit in 2 rows (6 columns) since
        // 11/2 = 6 columns comfortably clears the minimum cell width.
        let (rows, columns) = SIDOscilloscopeWindowController.gridLayout(
            count: 11, screenWidth: 2400, minCellWidth: 300)
        XCTAssertEqual(rows, 2)
        XCTAssertEqual(columns, 6)
        XCTAssertGreaterThanOrEqual(rows * columns, 11)
    }

    func testSIDOscilloscopeGridLayoutFallsBackToMoreRowsOnNarrowScreens() {
        // Same 11 modes on a much narrower screen: 2 rows (6 columns)
        // would make each cell narrower than the minimum, so it should
        // fall back to more, narrower rows instead.
        let (rows, columns) = SIDOscilloscopeWindowController.gridLayout(
            count: 11, screenWidth: 900, minCellWidth: 300)
        XCTAssertGreaterThan(rows, 2)
        XCTAssertLessThanOrEqual(columns, 3)
        XCTAssertGreaterThanOrEqual(rows * columns, 11)
    }

    func testSIDOscilloscopeGridLayoutHandlesTrivialCounts() {
        XCTAssertEqual(SIDOscilloscopeWindowController.gridLayout(count: 0, screenWidth: 1920, minCellWidth: 300).rows, 0)
        let single = SIDOscilloscopeWindowController.gridLayout(count: 1, screenWidth: 1920, minCellWidth: 300)
        XCTAssertEqual(single.rows, 1)
        XCTAssertEqual(single.columns, 1)
    }

    func testSIDWindowLayoutStoreRoundTripsThroughUserDefaults() throws {
        let id = UUID()
        defer { SIDWindowLayoutStore.clear(for: id) }
        XCTAssertNil(SIDWindowLayoutStore.load(for: id))
        XCTAssertFalse(SIDWindowLayoutStore.hasSavedLayout(for: id))

        let entries = [
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.oscilloscope.rawValue,
                frame: CGRect(x: 10, y: 20, width: 300, height: 180)),
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.spectrum.rawValue,
                frame: CGRect(x: 320, y: 20, width: 300, height: 180)),
        ]
        let saved = SIDWindowLayoutSnapshot(entries: entries, savedAt: Date())
        SIDWindowLayoutStore.save(saved, for: id)

        XCTAssertTrue(SIDWindowLayoutStore.hasSavedLayout(for: id))
        let loaded = try XCTUnwrap(SIDWindowLayoutStore.load(for: id))
        XCTAssertEqual(loaded.entries, entries)
    }

    func testSIDWindowLayoutStoreTreatsEmptyEntriesAsNoSavedLayout() {
        let id = UUID()
        defer { SIDWindowLayoutStore.clear(for: id) }
        SIDWindowLayoutStore.save(SIDWindowLayoutSnapshot(entries: [], savedAt: Date()), for: id)
        // An explicitly-saved empty layout (e.g. saved while no SID
        // windows were open) still decodes fine, but shouldn't be
        // reported as "something to restore" — `restoreWindowLayout()`
        // treats it as a no-op.
        XCTAssertFalse(SIDWindowLayoutStore.hasSavedLayout(for: id))
        XCTAssertNotNil(SIDWindowLayoutStore.load(for: id))
    }

    func testSIDWindowLayoutStoreClearRemovesSavedLayout() {
        let id = UUID()
        let entries = [SIDWindowLayoutEntry(mode: "Oscilloscope", frame: .zero)]
        SIDWindowLayoutStore.save(SIDWindowLayoutSnapshot(entries: entries, savedAt: Date()), for: id)
        XCTAssertTrue(SIDWindowLayoutStore.hasSavedLayout(for: id))

        SIDWindowLayoutStore.clear(for: id)
        XCTAssertNil(SIDWindowLayoutStore.load(for: id))
        XCTAssertFalse(SIDWindowLayoutStore.hasSavedLayout(for: id))
    }

    func testSIDWindowLayoutStoreOverwritesExistingLayout() throws {
        let id = UUID()
        defer { SIDWindowLayoutStore.clear(for: id) }
        let original = [
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.oscilloscope.rawValue,
                frame: CGRect(x: 10, y: 20, width: 300, height: 180)),
        ]
        SIDWindowLayoutStore.save(
            SIDWindowLayoutSnapshot(entries: original, savedAt: Date(timeIntervalSince1970: 1)),
            for: id)

        let replacement = [
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.spectrum.rawValue,
                frame: CGRect(x: 40, y: 60, width: 400, height: 220)),
            SIDWindowLayoutEntry(
                mode: SIDVisualizationMode.lissajous.rawValue,
                frame: CGRect(x: 450, y: 60, width: 400, height: 220)),
        ]
        SIDWindowLayoutStore.save(
            SIDWindowLayoutSnapshot(entries: replacement, savedAt: Date(timeIntervalSince1970: 2)),
            for: id)

        let loaded = try XCTUnwrap(SIDWindowLayoutStore.load(for: id))
        XCTAssertEqual(loaded.entries, replacement)
        XCTAssertEqual(loaded.savedAt, Date(timeIntervalSince1970: 2))
    }

    func testSIDSpectrumAnalyzerAutoGainAvoidsAllBarsPeggedAtMax() throws {
        let sampleRate = 48000.0
        let analyzer = SIDSpectrumAnalyzer(sampleRate: sampleRate)
        let toneHz = 1000.0

        var lastBars: [Float]?
        var phase = 0.0
        let totalSamples = SIDSpectrumAnalyzer.fftSize * 8
        var samples = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            samples[i] = Float(sin(phase))
            phase += 2 * Double.pi * toneHz / sampleRate
        }
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 256, samples.count)
            if let bars = analyzer.ingest(Array(samples[offset..<end])) {
                lastBars = bars
            }
            offset = end
        }

        let bars = try XCTUnwrap(lastBars)
        // A single pure tone should show a clear peak against a mostly-low
        // background, not a wall of maxed-out bars — an earlier fixed
        // "-60...0 dB" scale pegged nearly every bar to full-red
        // regardless of actual signal content, since the raw FFT
        // magnitude scale doesn't line up with that range.
        let peggedCount = bars.filter { $0 > 0.95 }.count
        XCTAssertLessThan(peggedCount, bars.count / 4)
    }

    func testSIDSpectrumAnalyzerReportsSilenceAsEmptyBarsNotAutoGainedNoise() throws {
        let analyzer = SIDSpectrumAnalyzer(sampleRate: 48000.0)

        // Genuine digital silence, plus the kind of tiny residual noise a
        // real audio path has even with nothing playing — the Ultimate
        // keeps streaming audio packets continuously whenever the stream
        // is running, whether or not anything is actually playing.
        // Auto-gain would otherwise rescale this relative to itself and
        // light up every bar exactly as if real music were loud.
        let totalSamples = SIDSpectrumAnalyzer.fftSize * 4
        var silence = [Float](repeating: 0, count: totalSamples)
        for i in silence.indices {
            // A tiny, deterministic "dither"-like wobble — well under
            // the silence threshold, but not literally all zeros.
            silence[i] = Float(sin(Double(i) * 0.7)) * 0.0002
        }

        var lastBars: [Float]?
        var offset = 0
        while offset < silence.count {
            let end = min(offset + 256, silence.count)
            if let bars = analyzer.ingest(Array(silence[offset..<end])) {
                lastBars = bars
            }
            offset = end
        }

        let bars = try XCTUnwrap(lastBars)
        XCTAssertTrue(bars.allSatisfy { $0 == 0 })
    }

    func testSIDNoteNameConversionMatchesStandardTuning() {
        XCTAssertEqual(SIDVoiceChannel.noteName(forHz: 440), "A4")
        XCTAssertEqual(SIDVoiceChannel.noteName(forHz: 261.63), "C4")
        XCTAssertEqual(SIDVoiceChannel.noteName(forHz: 0), "—")
        XCTAssertEqual(SIDVoiceChannel.midiNoteNumber(forHz: 440), 69)
        XCTAssertEqual(SIDVoiceChannel.midiNoteNumber(forHz: 261.63), 60)
        XCTAssertNil(SIDVoiceChannel.midiNoteNumber(forHz: 0))
    }

    func testSIDPianoKeyboardLayoutUsesFixedRange() {
        XCTAssertFalse(SIDPianoKeyboardLayout.isBlackKey(60)) // C4
        XCTAssertTrue(SIDPianoKeyboardLayout.isBlackKey(61))  // C#4
        XCTAssertEqual(SIDPianoKeyboardLayout.range.lowerBound % 12, 0)
        let whites = SIDPianoKeyboardLayout.whiteKeys()
        // C1…C7 is six full octaves of white keys plus the top C (7×6+1).
        XCTAssertEqual(whites.count, 43)
        XCTAssertEqual(whites.first, SIDPianoKeyboardLayout.minMidi) // C1
        XCTAssertEqual(whites.last, SIDPianoKeyboardLayout.maxMidi)  // C7
        XCTAssertTrue(SIDPianoKeyboardLayout.range.contains(96))
    }

    /// Covers the register read/write hex round-trip only — mode selection
    /// for the debug *stream* goes through `setConfigItem` (see
    /// `testMachineInputRequestAndServiceAutoEnable`/HANDOVER.md §14), not
    /// this register.
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

    func testUpdateServiceExpectedTeamIdentifierFallback() {
        XCTAssertEqual(UpdateService.fallbackTeamIdentifier, "EJ77LX9A8T")
        XCTAssertFalse(UpdateService.expectedTeamIdentifier().isEmpty)
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

    private func makeArchive(
        _ entries: [(String, Data, Entry.EntryType, CompressionMethod)]
    ) throws -> Data {
        let archive = try Archive(
            data: Data(), accessMode: .create, pathEncoding: nil)
        for (path, data, type, compression) in entries {
            try archive.addEntry(
                with: path,
                type: type,
                uncompressedSize: Int64(data.count),
                compressionMethod: compression) { position, size in
                    let start = Int(position)
                    guard start < data.count else { return Data() }
                    let end = min(start + size, data.count)
                    return data.subdata(in: start..<end)
                }
        }
        return try XCTUnwrap(archive.data)
    }

    private func makeSearchResult(
        id: String, category: Int, name: String
    ) throws -> Assembly64Client.SearchResult {
        let object: [String: Any] = [
            "id": id,
            "category": category,
            "name": name,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(
            Assembly64Client.SearchResult.self, from: data)
    }
}

private actor RecordingHTTPTransport: HTTPTransport {
    private var request: URLRequest?

    func recordedRequest() -> URLRequest? {
        return request
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (Data(#"{"errors":[]}"#.utf8), response)
    }
}

private actor ScriptedInputTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []

    var allInputEvents: [C64MachineInputEvent] {
        requests.compactMap(\.httpBody).flatMap {
            (try? JSONDecoder().decode(
                C64MachineInputEnvelope.self, from: $0).events) ?? []
        }
    }

    var inputEventCount: Int { allInputEvents.count }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let data: Data
        if path == "/v1/configs/Network Settings" {
            data = Data("""
            {"Network Settings":{
              "Ultimate DMA Service":"Disabled",
              "Web Remote Control Service":"Enabled"
            },"errors":[]}
            """.utf8)
        } else if path == "/v1/machine:readmem" {
            data = Data([0])
        } else {
            data = Data(#"{"errors":[]}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}

private actor FailingPressInputTransport: HTTPTransport {
    private(set) var sawReleaseAll = false

    func hasReleaseAll() -> Bool { sawReleaseAll }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let body = request.httpBody ?? Data()
        let events = (try? JSONDecoder().decode(
            C64MachineInputEnvelope.self,
            from: body).events) ?? []
        if events.contains(where: {
            $0.kind == .keyboard && $0.transition == .press
        }) {
            throw UltimateAPIClient.APIError.httpError(503, "temporary failure")
        }
        if events.contains(where: { $0.kind == .releaseAll }) {
            sawReleaseAll = true
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (Data(#"{"errors":[]}"#.utf8), response)
    }
}

private actor DelayedInputTransport: HTTPTransport {
    private var delayedRequest: CheckedContinuation<Void, Never>?
    private(set) var sawReleaseAll = false

    func hasReleaseAll() -> Bool { sawReleaseAll }

    func releaseDelayedRequest() {
        delayedRequest?.resume()
        delayedRequest = nil
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let body = request.httpBody ?? Data()
        let events = (try? JSONDecoder().decode(
            C64MachineInputEnvelope.self,
            from: body).events) ?? []
        if events.contains(where: {
            $0.kind == .keyboard && $0.transition == .press
        }) {
            await withCheckedContinuation { continuation in
                delayedRequest = continuation
            }
        }
        if events.contains(where: { $0.kind == .releaseAll }) {
            sawReleaseAll = true
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (Data(#"{"errors":[]}"#.utf8), response)
    }
}

private actor DebugRegisterHTTPTransport: HTTPTransport {
    private(set) var lastRequest: URLRequest?

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(#"{"value":"0x2C","errors":[]}"#.utf8), response)
    }
}

private actor MenuScreenHTTPTransport: HTTPTransport {
    private(set) var lastRequest: URLRequest?

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        lastRequest = request
        var bytes = Data(repeating: 0, count: 2000)
        bytes[0] = 1
        bytes[1000] = 0x16
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        return (bytes, response)
    }
}