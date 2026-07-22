import XCTest
import ZIPFoundation
import MetalKit
@testable import Stream64

final class Assembly64FeatureTests: XCTestCase {
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
                videoPort: 11000, audioPort: 11001),
            UltimateDevice(
                name: "Two", host: "192.168.1.21",
                videoPort: 11002, audioPort: 11003),
        ]

        let device = UltimateDevice.makeDefault(avoiding: existing)

        XCTAssertEqual(device.videoPort, 11004)
        XCTAssertEqual(device.audioPort, 11005)
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
    }

    @MainActor
    func testEmbeddedMetalShadersCompile() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable")
        }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertNotNil(MetalFrameRenderer(mtkView: view))
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