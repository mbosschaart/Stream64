import XCTest
@testable import Stream64

final class WorkspaceSnapshotTests: XCTestCase {
    override func tearDown() {
        WorkspaceSnapshotStore.resetSessionFlagsForTests()
        WorkspaceSnapshotStore.clear()
        MainViewerFrameStore.clear()
        super.tearDown()
    }

    func testWorkspaceSnapshotStoreRoundTrips() throws {
        let deviceID = UUID()
        let snapshot = WorkspaceSnapshot(
            entries: [
                WorkspaceWindowEntry(
                    kind: .mainViewer,
                    frame: CGRect(x: 10, y: 20, width: 900, height: 600),
                    isFullScreen: true),
                WorkspaceWindowEntry(
                    kind: .assembly64,
                    frame: CGRect(x: 100, y: 80, width: 980, height: 680)),
                WorkspaceWindowEntry(
                    kind: .sidOscilloscope,
                    frame: CGRect(x: 40, y: 40, width: 400, height: 240),
                    deviceID: deviceID,
                    sidMode: "Spectrum Analyzer",
                    isMiniaturized: true),
            ],
            savedAt: Date(timeIntervalSince1970: 1_700_000_000))

        WorkspaceSnapshotStore.save(snapshot)
        let loaded = try XCTUnwrap(WorkspaceSnapshotStore.load())
        XCTAssertEqual(loaded.entries.count, 3)
        XCTAssertEqual(loaded.entries[0].kind, .mainViewer)
        XCTAssertTrue(loaded.entries[0].isFullScreen)
        XCTAssertEqual(loaded.entries[1].kind, .assembly64)
        XCTAssertEqual(loaded.entries[2].deviceID, deviceID)
        XCTAssertEqual(loaded.entries[2].sidMode, "Spectrum Analyzer")
        XCTAssertTrue(loaded.entries[2].isMiniaturized)
    }

    func testWorkspaceSnapshotStoreClearRemovesSnapshot() {
        WorkspaceSnapshotStore.save(
            WorkspaceSnapshot(entries: [
                WorkspaceWindowEntry(
                    kind: .help,
                    frame: .zero),
            ], savedAt: Date()))
        XCTAssertNotNil(WorkspaceSnapshotStore.load())
        WorkspaceSnapshotStore.clear()
        XCTAssertNil(WorkspaceSnapshotStore.load())
    }

    func testMainViewerFrameStoreRoundTrips() throws {
        MainViewerFrameStore.save(.init(
            frame: CGRect(x: 120, y: 80, width: 1280, height: 800),
            isMiniaturized: false,
            isFullScreen: false))
        let loaded = try XCTUnwrap(MainViewerFrameStore.load())
        XCTAssertEqual(loaded.frame.width, 1280)
        XCTAssertEqual(loaded.frame.height, 800)
        XCTAssertEqual(loaded.frame.origin, CGPoint(x: 120, y: 80))
    }

    func testUpsertReplacesSameIdentity() throws {
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .assembly64,
            frame: CGRect(x: 0, y: 0, width: 900, height: 600)))
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .assembly64,
            frame: CGRect(x: 50, y: 60, width: 1000, height: 700)))
        let loaded = try XCTUnwrap(WorkspaceSnapshotStore.load())
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[0].frame.width, 1000)
        XCTAssertEqual(loaded.entries[0].frame.origin.x, 50)
    }

    func testRemoveDropsEntry() throws {
        let deviceID = UUID()
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .hvsc,
            frame: CGRect(x: 0, y: 0, width: 900, height: 600)))
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .driveBay,
            frame: CGRect(x: 10, y: 10, width: 560, height: 400),
            deviceID: deviceID))
        WorkspaceSnapshotStore.remove(kind: .hvsc)
        let loaded = try XCTUnwrap(WorkspaceSnapshotStore.load())
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[0].kind, .driveBay)
    }

    func testUpdateFrameChangesGeometryOnly() throws {
        let deviceID = UUID()
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .debugTrace,
            frame: CGRect(x: 0, y: 0, width: 760, height: 480),
            deviceID: deviceID))
        WorkspaceSnapshotStore.updateFrame(
            kind: .debugTrace,
            deviceID: deviceID,
            frame: CGRect(x: 20, y: 30, width: 800, height: 500),
            isMiniaturized: true,
            isFullScreen: false)
        let loaded = try XCTUnwrap(WorkspaceSnapshotStore.load())
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[0].frame.width, 800)
        XCTAssertTrue(loaded.entries[0].isMiniaturized)
        XCTAssertEqual(loaded.entries[0].deviceID, deviceID)
    }

    func testUpsertIgnoredWhileRestoring() throws {
        MainViewerFrameStore.save(.init(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            isMiniaturized: false,
            isFullScreen: false))
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .mainViewer,
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800)))

        WorkspaceSnapshotStore.beginRestore()
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .mainViewer,
            frame: CGRect(x: 0, y: 0, width: 900, height: 620)))
        // Tool windows may record during restore; only main viewer is gated.
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .assembly64,
            frame: CGRect(x: 0, y: 0, width: 980, height: 680)))
        WorkspaceSnapshotStore.endRestore()

        let loaded = try XCTUnwrap(WorkspaceSnapshotStore.load())
        XCTAssertEqual(loaded.entries.count, 2)
        XCTAssertEqual(
            loaded.entries.first { $0.kind == .mainViewer }?.frame.width, 1280)
        XCTAssertEqual(
            loaded.entries.first { $0.kind == .assembly64 }?.frame.width, 980)
        XCTAssertEqual(MainViewerFrameStore.load()?.frame.width, 1280)
    }

    func testUpsertForcedWritesMainViewerDuringRestore() throws {
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .mainViewer,
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800)))
        WorkspaceSnapshotStore.beginRestore()
        WorkspaceSnapshotStore.upsertForced(WorkspaceWindowEntry(
            kind: .mainViewer,
            frame: CGRect(x: 10, y: 20, width: 1400, height: 900)))
        WorkspaceSnapshotStore.endRestore()
        let loaded = try XCTUnwrap(WorkspaceSnapshotStore.load())
        XCTAssertEqual(loaded.entries[0].frame.width, 1400)
    }

    func testRemoveAllowedWhileRestoring() throws {
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .fileManager,
            frame: CGRect(x: 0, y: 0, width: 1180, height: 760)))
        WorkspaceSnapshotStore.beginRestore()
        WorkspaceSnapshotStore.remove(kind: .fileManager)
        WorkspaceSnapshotStore.endRestore()
        let loaded = WorkspaceSnapshotStore.load()
        XCTAssertTrue(loaded?.entries.isEmpty ?? true)
    }

    func testRemoveIgnoredWhileTerminating() throws {
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .assembly64,
            frame: CGRect(x: 0, y: 0, width: 980, height: 680)))
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .hvsc,
            frame: CGRect(x: 10, y: 10, width: 980, height: 680)))
        WorkspaceSnapshotStore.beginTermination()
        WorkspaceSnapshotStore.remove(kind: .assembly64)
        WorkspaceSnapshotStore.remove(kind: .hvsc)
        let loaded = try XCTUnwrap(WorkspaceSnapshotStore.load())
        XCTAssertEqual(loaded.entries.count, 2)
    }

    func testMainViewerUpsertMirrorsFrameStore() throws {
        WorkspaceSnapshotStore.upsert(WorkspaceWindowEntry(
            kind: .mainViewer,
            frame: CGRect(x: 40, y: 50, width: 1400, height: 900),
            isFullScreen: true))
        let frame = try XCTUnwrap(MainViewerFrameStore.load())
        XCTAssertEqual(frame.frame.width, 1400)
        XCTAssertTrue(frame.isFullScreen)
        XCTAssertEqual(MainViewerFrameStore.preferredSize.width, 1400)
    }
}
