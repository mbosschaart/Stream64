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

    func testMemoryHeatmapRecordsReadsAndWritesIndependently() {
        let heatmap = MemoryHeatmap()
        let readWord: UInt32 = (1 << 24) | UInt32(0x1234) // R/W#=1 (read)
        let writeWord: UInt32 = UInt32(0x5678)            // R/W#=0 (write)
        let readEntry = DebugStreamEntry(word: readWord, source: .cpu6510)
        let writeEntry = DebugStreamEntry(word: writeWord, source: .cpu6510)

        heatmap.record([readEntry, writeEntry])

        XCTAssertGreaterThan(heatmap.lastRead[0x1234], 0)
        XCTAssertEqual(heatmap.lastWrite[0x1234], 0)
        XCTAssertGreaterThan(heatmap.lastWrite[0x5678], 0)
        XCTAssertEqual(heatmap.lastRead[0x5678], 0)

        heatmap.reset()
        XCTAssertEqual(heatmap.lastRead[0x1234], 0)
        XCTAssertEqual(heatmap.lastWrite[0x5678], 0)
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

    func testSIDNoteNameConversionMatchesStandardTuning() {
        XCTAssertEqual(SIDVoiceChannel.noteName(forHz: 440), "A4")
        XCTAssertEqual(SIDVoiceChannel.noteName(forHz: 261.63), "C4")
        XCTAssertEqual(SIDVoiceChannel.noteName(forHz: 0), "—")
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