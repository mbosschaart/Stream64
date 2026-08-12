import XCTest
import CryptoKit
import ZIPFoundation
import MetalKit
import AVFoundation
@testable import Stream64

final class CommanderTests: XCTestCase {
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


}
