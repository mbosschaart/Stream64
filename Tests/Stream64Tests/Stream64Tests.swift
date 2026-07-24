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