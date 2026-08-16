import CryptoKit
import XCTest
@testable import Stream64

final class HVSCTests: XCTestCase {
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
