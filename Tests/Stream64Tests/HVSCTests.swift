import CryptoKit
import XCTest
@testable import Stream64

final class HVSCTests: XCTestCase {
    func testLocalCollectionFiltersUseIndexedSIDHeaderCounts() {
        let tunes = [
            makeLocalTune(path: "One.sid", sidCount: 1),
            makeLocalTune(path: "Two.sid", sidCount: 2),
            makeLocalTune(path: "Three.sid", sidCount: 3),
        ]

        XCTAssertEqual(
            HVSCLocalLibrary.filteredTunes(tunes, collection: .twoSID)
                .map(\.relativePath),
            ["Two.sid"])
        XCTAssertEqual(
            HVSCLocalLibrary.filteredTunes(tunes, collection: .threeSID)
                .map(\.relativePath),
            ["Three.sid"])
        XCTAssertEqual(
            HVSCLocalLibrary.filteredTunes(tunes, terms: ["three"], collection: .all)
                .map(\.relativePath),
            ["Three.sid"])
    }

    func testCompatibleUpdateRequiresManifestVersionMatch() {
        let manifest = HVSCManifestClient.Manifest(
            version: 84,
            update: .init(
                requiredVersion: 83,
                url: URL(string: "https://hvsc.de/HVSC_83_to_84.7z")!),
            complete: .init(
                requiredVersion: nil,
                url: URL(string: "https://hvsc.de/HVSC_84_AllOfIt.7z")!))

        XCTAssertTrue(HVSCLocalLibrary.isCompatibleUpdate(
            installedVersion: 83,
            manifest: manifest))
        XCTAssertFalse(HVSCLocalLibrary.isCompatibleUpdate(
            installedVersion: 82,
            manifest: manifest))
    }

    func testHVSCArchiveValidationRejectsTraversalLinksAndDuplicatePaths() {
        XCTAssertThrowsError(try HVSCLocalLibrary.validateArchiveEntries([
            .init(path: "../outside.sid", isLinkOrSpecial: false),
        ]))
        XCTAssertThrowsError(try HVSCLocalLibrary.validateArchiveEntries([
            .init(path: "HVSC/MUSICIANS/A/Tune.sid", isLinkOrSpecial: true),
        ]))
        XCTAssertThrowsError(try HVSCLocalLibrary.validateArchiveEntries([
            .init(path: "HVSC/MUSICIANS/A/Tune.sid", isLinkOrSpecial: false),
            .init(path: "hvsc/musicians/a/tune.SID", isLinkOrSpecial: false),
        ]))
    }

    func testHVSCExtractedCorpusRequiresMusiciansAndSIDFiles() throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("HVSC/MUSICIANS/A", isDirectory: true),
            withIntermediateDirectories: true)
        try Data([0]).write(to: staging.appendingPathComponent("HVSC/MUSICIANS/A/Test.sid"))

        XCTAssertEqual(
            try HVSCLocalLibrary.validatedCorpusRoot(in: staging).lastPathComponent,
            "HVSC")

        try FileManager.default.removeItem(at: staging.appendingPathComponent("HVSC/MUSICIANS/A/Test.sid"))
        XCTAssertThrowsError(try HVSCLocalLibrary.validatedCorpusRoot(in: staging))
    }

    @MainActor
    func testChoosingLocalHVSCRequiresC64MusicFolder() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("C64Music/MUSICIANS", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("C64Music/DOCUMENTS", isDirectory: true),
            withIntermediateDirectories: true)

        let library = HVSCLocalLibrary()
        library.chooseRoot(parent)
        guard case let .failed(message) = library.status else {
            return XCTFail("Expected parent folder to be rejected")
        }
        XCTAssertTrue(message.contains("C64Music"))
    }

    func testSonglengthDatabaseParsesCurrentFormatAndMilliseconds() throws {
        let database = try HVSCSonglengthDatabase.parse(Data("""
        [Database]
        ; /MUSICIANS/T/Test/Tune.sid
        900150983cd24fb0d6963f7d28e17f72=1:02 0:06.5 0:01.007
        """.utf8))

        XCTAssertEqual(
            database.durationsByMD5["900150983cd24fb0d6963f7d28e17f72"],
            [62_000, 6_500, 1_007])
        XCTAssertEqual(database.durations(for: Data("abc".utf8)), [
            62_000, 6_500, 1_007,
        ])
    }

    func testSonglengthDatabaseRejectsLegacyOrMalformedInput() {
        XCTAssertThrowsError(
            try HVSCSonglengthDatabase.parse(Data("""
            ; no current database header
            900150983cd24fb0d6963f7d28e17f72=1:02(G)
            """.utf8)))
        XCTAssertThrowsError(
            try HVSCSonglengthDatabase.parse(Data("""
            [Database]
            900150983cd24fb0d6963f7d28e17f72=1:99
            """.utf8)))
    }

    @MainActor
    func testSonglengthImportPersistsAndFailurePreservesPreviousDatabase() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let playlistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: playlistURL)
        }

        let data = Data("""
        [Database]
        900150983cd24fb0d6963f7d28e17f72=2:34
        """.utf8)
        let store = HVSCLibraryStore(
            storeURL: url,
            playlistURL: playlistURL)
        await store.importSonglengths(data)
        XCTAssertEqual(store.durations(for: Data("abc".utf8)), [154_000])
        XCTAssertEqual(store.songlengthInfo?.entryCount, 1)

        await store.importSonglengths(Data("[Database]\nbroken\n".utf8))
        XCTAssertEqual(store.durations(for: Data("abc".utf8)), [154_000])

        let reloaded = HVSCLibraryStore(
            storeURL: url,
            playlistURL: playlistURL)
        XCTAssertEqual(reloaded.durations(for: Data("abc".utf8)), [154_000])
    }

    @MainActor
    func testPlaylistPersistsWithoutDuplicateTunes() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let playlistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: playlistURL)
        }

        let tune = try makeTuneDetail(id: 101, title: "Playlist Tune")
        let store = HVSCLibraryStore(
            storeURL: storeURL,
            playlistURL: playlistURL)
        store.addToPlaylist(tune)
        store.addToPlaylist(tune)

        XCTAssertEqual(store.playlist.map(\.tune.id), [101])

        let reloaded = HVSCLibraryStore(
            storeURL: storeURL,
            playlistURL: playlistURL)
        XCTAssertEqual(reloaded.playlist.map(\.tune.title), ["Playlist Tune"])
    }

    @MainActor
    func testLocalPathPlaylistPersistsOrderAndRetainsUnavailableEntries() {
        let playlistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: playlistURL) }

        let first = makeLocalTune(path: "MUSICIANS/A/First.sid", sidCount: 1)
        let second = makeLocalTune(path: "MUSICIANS/B/Second.sid", sidCount: 1)
        let library = HVSCLocalLibrary(playlistURL: playlistURL)
        library.addToPlaylist(first)
        library.addToPlaylist(second)
        library.addToPlaylist(first)
        library.movePlaylistEntry(from: 1, by: -1)

        XCTAssertEqual(library.playlist.map(\.relativePath), [
            "MUSICIANS/B/Second.sid",
            "MUSICIANS/A/First.sid",
        ])
        XCTAssertNil(library.tune(for: library.playlist[0]))

        let reloaded = HVSCLocalLibrary(playlistURL: playlistURL)
        XCTAssertEqual(reloaded.playlist.map(\.relativePath), [
            "MUSICIANS/B/Second.sid",
            "MUSICIANS/A/First.sid",
        ])
    }

    func testSIDHeaderParsesPSIDv4AndAdditionalSIDs() throws {
        var data = Data(repeating: 0, count: 0x90)
        data.replaceSubrange(0..<4, with: Data("PSID".utf8))
        writeWord(4, at: 0x04, in: &data)
        writeWord(0x7C, at: 0x06, in: &data)
        writeWord(3, at: 0x0E, in: &data)
        writeWord(2, at: 0x10, in: &data)
        writeText("Test Tune", at: 0x16, in: &data)
        writeText("Test Author", at: 0x36, in: &data)
        writeWord(0x00C8, at: 0x76, in: &data)
        data[0x7A] = 0x42
        data[0x7B] = 0x44

        let header = try SIDHeader(data: data)

        XCTAssertEqual(header.format, .psid)
        XCTAssertEqual(header.version, 4)
        XCTAssertEqual(header.title, "Test Tune")
        XCTAssertEqual(header.author, "Test Author")
        XCTAssertEqual(header.numberOfSongs, 3)
        XCTAssertEqual(header.startSong, 2)
        XCTAssertEqual(header.secondSIDAddress, 0xD420)
        XCTAssertEqual(header.thirdSIDAddress, 0xD440)
    }

    func testSIDHeaderRejectsMalformedAdditionalSIDAndReadsModels() throws {
        var data = makeSIDHeader(version: 3, flags: 0x00A0)
        data[0x7A] = 0x42

        let header = try SIDHeader(data: data)
        XCTAssertEqual(header.primarySIDModel, "8580")
        XCTAssertEqual(header.secondSIDModel, "8580")
        XCTAssertEqual(header.requiredSIDAddresses, [0xD400, 0xD420])

        data[0x7A] = 0x41
        XCTAssertThrowsError(try SIDHeader(data: data))
    }

    func testSIDHeaderRejectsInvalidMagicAndSongRange() {
        XCTAssertThrowsError(try SIDHeader(data: Data(repeating: 0, count: 0x7C)))

        var data = Data(repeating: 0, count: 0x80)
        data.replaceSubrange(0..<4, with: Data("PSID".utf8))
        writeWord(2, at: 0x04, in: &data)
        writeWord(0x7C, at: 0x06, in: &data)
        writeWord(1, at: 0x0E, in: &data)
        writeWord(2, at: 0x10, in: &data)
        XCTAssertThrowsError(try SIDHeader(data: data))
    }

    func testHVSCSearchAndDetailDecodeWebsitePayloads() throws {
        let results = try JSONDecoder().decode(
            [HVSCClient.SearchResult].self,
            from: Data("""
            [{"id":127097,"title":"Crome vs Turrican 2002",
              "author":"Siegfried Rudzynski (Crome)",
              "released":"2003 People of Liberty"}]
            """.utf8))
        XCTAssertEqual(results.first?.id, 127097)

        let detail = try JSONDecoder().decode(
            HVSCClient.TuneDetail.self,
            from: Data("""
            {"id":127097,"filename":"Crome_vs_Turrican_2002.sid",
             "fileFormat":"PSID","fileFormatVersion":2,
             "title":"Crome vs Turrican 2002",
             "author":"Siegfried Rudzynski (Crome)",
             "released":"2003 People of Liberty",
             "speed":"00000000","systemPal":true,"systemNtsc":false,
             "model6581":true,"model8580":false,"basic":false,
             "playsidSpecific":false,"loadAddress":"1000",
             "initAddress":"1000","playAddress":"1003",
             "startSong":1,"numberOfSongs":1,
             "freePagesStart":"00","freePagesLength":"00",
             "md5":"7c3b0ffacd37054126a3ddb55e3c5b46",
             "model6581Sid2":true,"model8580Sid2":false,
             "sid2BaseAddress":null,"model6581Sid3":false,
             "model8580Sid3":false,"sid3BaseAddress":null,
             "filePath":"/MUSICIANS/C/Crome/"}
            """.utf8))
        XCTAssertEqual(detail.relativePath, "/MUSICIANS/C/Crome/Crome_vs_Turrican_2002.sid")
        XCTAssertEqual(detail.videoStandard, "PAL")
        XCTAssertEqual(detail.sidRequirements, "6581")
    }

    func testLegacySearchAPIIsLocalOnlyAndResultsCanStillBeNarrowed() throws {
        var filters = HVSCClient.SearchFilters()
        filters.model = .mos8580
        filters.collection = .twoSID

        let twoSIDURL = try HVSCClient.searchURL(
            query: try XCTUnwrap(filters.collection.searchToken),
            filters: filters)
        XCTAssertEqual(twoSIDURL, HVSCManifestClient.manifestURL)

        filters.collection = .threeSID
        let threeSIDURL = try HVSCClient.searchURL(
            query: try XCTUnwrap(filters.collection.searchToken),
            filters: filters)
        XCTAssertEqual(threeSIDURL, HVSCManifestClient.manifestURL)

        let result = HVSCClient.SearchResult(
            id: 1,
            title: "A Walk in the Countryside",
            author: "Gaetano Chiummo",
            released: "2014 Samar Productions")
        XCTAssertTrue(result.matches("countryside"))
        XCTAssertTrue(result.matches("CHI"))
        XCTAssertFalse(result.matches("Turrican"))
    }

    func testPSID64ConversionKeepsScreenAndValidatesPRGOutput() {
        let input = URL(fileURLWithPath: "/tmp/input.sid")
        let output = URL(fileURLWithPath: "/tmp/output.prg")

        XCTAssertEqual(
            PSID64Service.conversionArguments(output: output, input: input),
            ["--output", "/tmp/output.prg", "/tmp/input.sid"])
        XCTAssertFalse(PSID64Service.isValidPRG(Data([0x01, 0x08])))
        XCTAssertTrue(PSID64Service.isValidPRG(Data([0x01, 0x08, 0x60])))
    }

    func testSIDConfigurationReadsModelsAndFixesSecondAddress() async throws {
        let transport = SIDConfigurationTransport()
        let client = UltimateAPIClient(
            device: UltimateDevice(name: "Test", host: "192.168.1.64"),
            transport: transport)

        let configuration = await client.fetchSIDConfiguration()
        XCTAssertEqual(configuration.socket1Address, 0xD400)
        XCTAssertEqual(configuration.socket1Model, "8580")
        XCTAssertEqual(configuration.socket2Address, 0xD420)
        XCTAssertEqual(configuration.socket2Model, "8580")

        try await client.setSecondSIDAddress(0xD500)

        let requests = await transport.recordedRequests()
        let addressRequest = try XCTUnwrap(requests.first {
            $0.url?.path.contains("SID Socket 2 Address") == true
                && $0.httpMethod == "PUT"
        })
        let items = URLComponents(
            url: try XCTUnwrap(addressRequest.url),
            resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "value" })?.value, "$D500")
        XCTAssertTrue(requests.contains {
            $0.url?.path == "/v1/configs/SID Addressing:save_to_flash"
        })
    }

    func testSIDAutoRoutingPersistsPSIDv3SecondAddressAndWarnsPhysicalMismatch() async throws {
        let transport = SIDConfigurationTransport()
        let client = UltimateAPIClient(
            device: UltimateDevice(name: "Test", host: "192.168.1.64"),
            transport: transport)
        var twoSID = makeSIDHeader(version: 3, flags: 0x00A0)
        twoSID[0x7A] = 0x50

        let route = try await client.ensureSIDRouting(
            for: SIDHeader(data: twoSID))
        XCTAssertEqual(route.configuredSlots, [.socket2])
        let requests = await transport.recordedRequests()
        let addressRequest = try XCTUnwrap(requests.first {
            $0.url?.path.contains("SID Socket 2 Address") == true
        })
        let items = URLComponents(
            url: try XCTUnwrap(addressRequest.url),
            resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "value" })?.value, "$D500")
        XCTAssertTrue(requests.contains {
            $0.url?.path == "/v1/configs/SID Addressing:save_to_flash"
        })

        var incompatible = makeSIDHeader(version: 3, flags: 0x0050)
        incompatible[0x7A] = 0x50
        let mismatchTransport = SIDConfigurationTransport()
        let mismatchClient = UltimateAPIClient(
            device: UltimateDevice(name: "Test", host: "192.168.1.64"),
            transport: mismatchTransport)
        let mismatchRoute = try await mismatchClient.ensureSIDRouting(
            for: SIDHeader(data: incompatible))
        XCTAssertEqual(mismatchRoute.configuredSlots, [.socket2])
        XCTAssertEqual(mismatchRoute.warnings.count, 2)
        let mismatchRequests = await mismatchTransport.recordedRequests()
        XCTAssertTrue(mismatchRequests.contains {
            $0.url?.path.contains("SID Socket 2 Address") == true
        })
        XCTAssertFalse(mismatchRequests.contains {
            $0.httpMethod == "PUT"
                && $0.url?.path.contains("UltiSID Configuration") == true
        })
        XCTAssertFalse(mismatchRequests.contains {
            $0.url?.path == "/v1/runners:sidplay"
        })
    }

    func testFounderUsesUltiSIDAddressesWhenPhysicalSocketsDisabled() async {
        let transport = SIDConfigurationTransport(founder: true)
        let client = UltimateAPIClient(
            device: UltimateDevice(name: "Founder", host: "172.16.10.64"),
            transport: transport)

        let configuration = await client.fetchSIDConfiguration()

        XCTAssertEqual(configuration.socket1Address, 0xD400)
        XCTAssertEqual(configuration.socket1Model, "8580")
        XCTAssertEqual(configuration.socket2Address, 0xD420)
        XCTAssertEqual(configuration.socket2Model, "8580")
        XCTAssertEqual(configuration.secondSIDSource, .ultiSID)

        var twoSID6581 = makeSIDHeader(version: 3, flags: 0x0050)
        twoSID6581[0x7A] = 0x42
        let route = try? await client.ensureSIDRouting(
            for: SIDHeader(data: twoSID6581))
        XCTAssertEqual(route?.warnings, [])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter {
                $0.url?.path.contains("UltiSID") == true
                    && $0.url?.path.contains("Filter Curve") == true
            }.count,
            2)
        XCTAssertTrue(requests.contains {
            $0.url?.path == "/v1/configs/UltiSID Configuration:save_to_flash"
        })
    }

    private func writeWord(_ value: Int, at offset: Int, in data: inout Data) {
        data[offset] = UInt8((value >> 8) & 0xFF)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeText(_ value: String, at offset: Int, in data: inout Data) {
        for (index, byte) in value.utf8.prefix(31).enumerated() {
            data[offset + index] = byte
        }
    }

    private func makeSIDHeader(version: Int, flags: Int) -> Data {
        var data = Data(repeating: 0, count: 0x90)
        data.replaceSubrange(0..<4, with: Data("PSID".utf8))
        writeWord(version, at: 0x04, in: &data)
        writeWord(0x7C, at: 0x06, in: &data)
        writeWord(1, at: 0x0E, in: &data)
        writeWord(1, at: 0x10, in: &data)
        writeWord(flags, at: 0x76, in: &data)
        return data
    }

    private func makeTuneDetail(id: Int, title: String) throws -> HVSCClient.TuneDetail {
        try JSONDecoder().decode(
            HVSCClient.TuneDetail.self,
            from: Data("""
            {"id":\(id),"filename":"Tune.sid","fileFormat":"PSID",
             "fileFormatVersion":2,"title":"\(title)","author":"Author",
             "released":"2026 Test","speed":"00000000","systemPal":true,
             "systemNtsc":false,"model6581":true,"model8580":false,
             "basic":false,"playsidSpecific":false,"loadAddress":"1000",
             "initAddress":"1000","playAddress":"1003","startSong":1,
             "numberOfSongs":1,"freePagesStart":"00","freePagesLength":"00",
             "md5":"7c3b0ffacd37054126a3ddb55e3c5b46",
             "model6581Sid2":false,"model8580Sid2":false,
             "sid2BaseAddress":null,"model6581Sid3":false,
             "model8580Sid3":false,"sid3BaseAddress":null,
             "filePath":"/MUSICIANS/T/Test/"}
            """.utf8))
    }

    private func makeLocalTune(path: String, sidCount: Int) -> LocalHVSCTune {
        .init(
            relativePath: path,
            title: path,
            author: "Author",
            released: "2026",
            format: "PSID",
            songs: 1,
            startSong: 1,
            sidRequirements: "\(sidCount)SID",
            sidCount: sidCount)
    }
}

private actor SIDConfigurationTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private let founder: Bool

    init(founder: Bool = false) {
        self.founder = founder
    }

    func recordedRequests() -> [URLRequest] { requests }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let body: Data
        if path.contains("SID Addressing"), request.httpMethod == "GET" {
            body = Data("""
            {"SID Addressing":{
              "SID Socket 1 Address":"$D400",
              "SID Socket 2 Address":"$D420",
              "UltiSID 1 Address":"$D400",
              "UltiSID 2 Address":"$D420"
            },"errors":[]}
            """.utf8)
        } else if path.contains("SID Sockets Configuration") {
            body = Data((founder
                ? """
                {"SID Sockets Configuration":{
                  "SID Socket 1":"Disabled",
                  "SID Socket 2":"Disabled",
                  "SID Detected Socket 1":"None",
                  "SID Detected Socket 2":"None"
                },"errors":[]}
                """
                : """
                {"SID Sockets Configuration":{
                  "SID Socket 1":"Enabled",
                  "SID Socket 2":"Enabled",
                  "SID Detected Socket 1":"8580",
                  "SID Detected Socket 2":"8580"
                },"errors":[]}
                """).utf8)
        } else if path.contains("UltiSID Configuration") {
            body = Data("""
            {"UltiSID Configuration":{
              "UltiSID 1 Filter Curve":"8580 Lo",
              "UltiSID 2 Filter Curve":"8580 Lo"
            },"errors":[]}
            """.utf8)
        } else {
            body = Data(#"{"errors":[]}"#.utf8)
        }
        return (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
        )
    }
}
