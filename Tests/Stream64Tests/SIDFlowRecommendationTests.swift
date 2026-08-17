import XCTest
@testable import Stream64

final class SIDFlowRecommendationTests: XCTestCase {
    /// Optional release-contract test. CI remains hermetic, while a developer
    /// can point it at a downloaded release artifact to validate the actual
    /// public bundle rather than only the compact fixture below.
    func testPublishedLiteBundleWhenPathsAreProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let bundlePath = environment["SIDFLOW_LITE_BUNDLE"],
              let manifestPath = environment["SIDFLOW_LITE_MANIFEST"] else {
            throw XCTSkip("Set SIDFLOW_LITE_BUNDLE and SIDFLOW_LITE_MANIFEST to validate a published release.")
        }
        let manifest = try JSONDecoder().decode(
            SIDFlowLiteManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let data = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
        let bundle = try SIDFlowLiteBundle(data: data, manifest: manifest)
        XCTAssertEqual(bundle.tracks.count, manifest.trackCount)
        let seed = try XCTUnwrap(bundle.tracks.first).key
        let recommendations = bundle.recommendations(
            seededBy: [seed],
            excluding: [],
            limit: 10)
        XCTAssertFalse(recommendations.isEmpty)
        XCTAssertFalse(recommendations.contains { $0.key == seed })
    }

    @MainActor
    func testInstalledRadioStoreWhenCachePathIsProvided() throws {
        guard let cachePath = ProcessInfo.processInfo.environment["SIDFLOW_STORE_CACHE"] else {
            throw XCTSkip("Set SIDFLOW_STORE_CACHE to validate an installed Stream64 SID Station cache.")
        }
        let store = SIDFlowRecommendationStore(
            cacheDirectory: URL(fileURLWithPath: cachePath, isDirectory: true))
        XCTAssertTrue(store.isInstalled)
        XCTAssertFalse(store.likedKeys.isEmpty)
        XCTAssertFalse(store.recommendations.isEmpty)
    }

    func testChecksumParserRequiresTheExactBundleName() throws {
        let digest = String(repeating: "a", count: 64)
        let sums = Data("""
        \(digest)  sidcorr-hvsc-full-sidcorr-lite-1.sidcorr
        \(String(repeating: "b", count: 64))  another.sidcorr
        """.utf8)
        XCTAssertEqual(
            try SIDFlowRecommendationStore.checksum(
                for: "sidcorr-hvsc-full-sidcorr-lite-1.sidcorr",
                in: sums),
            digest)
        XCTAssertThrowsError(try SIDFlowRecommendationStore.checksum(
            for: "missing.sidcorr", in: sums))
    }

    func testLiteBundleDecodesTrackIdentityAndNeighbours() throws {
        let data = makeLiteFixture()
        let manifest = makeManifest(bundleBytes: data.count)
        let bundle = try SIDFlowLiteBundle(data: data, manifest: manifest)

        let first = SIDFlowTrackKey(
            sidPath: "/MUSICIANS/A/Artist/First.sid",
            songIndex: 0)
        XCTAssertEqual(bundle.tracks.count, 2)
        XCTAssertEqual(bundle.tracks[0].key, first)
        XCTAssertEqual(bundle.tracks[1].key.songIndex, 1)

        let recommendations = bundle.recommendations(
            seededBy: [first],
            excluding: [],
            limit: 5)
        XCTAssertEqual(recommendations.map(\.key.sidPath), [
            "/MUSICIANS/A/Artist/Second.sid",
        ])
        XCTAssertEqual(try XCTUnwrap(recommendations.first).score, 1, accuracy: 0.001)
    }

    func testLiteBundleRejectsIncorrectManifestCountAndBadFooter() throws {
        let data = makeLiteFixture()
        var wrongCount = makeManifest(bundleBytes: data.count)
        wrongCount = SIDFlowLiteManifest(
            schemaVersion: wrongCount.schemaVersion,
            generatedAt: wrongCount.generatedAt,
            corpusVersion: wrongCount.corpusVersion,
            hvscVersion: wrongCount.hvscVersion,
            trackCount: 3,
            fileCount: wrongCount.fileCount,
            vectorDimensions: wrongCount.vectorDimensions,
            similarityMetric: wrongCount.similarityMetric,
            vectorWeights: wrongCount.vectorWeights,
            bundleBytes: wrongCount.bundleBytes,
            fileChecksums: wrongCount.fileChecksums)
        XCTAssertThrowsError(try SIDFlowLiteBundle(data: data, manifest: wrongCount))

        XCTAssertThrowsError(try SIDFlowLiteBundle(
            data: data.dropLast(),
            manifest: makeManifest(bundleBytes: data.count - 1)))
    }

    @MainActor
    func testRadioPreferencesExcludeSkippedAndRecentTracksWithoutSIDFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SIDFlowRecommendationStore(cacheDirectory: directory)
        let first = SIDFlowTrackKey(
            sidPath: "MUSICIANS/A/Artist/First.sid", songIndex: 1)
        let second = SIDFlowTrackKey(
            sidPath: "/MUSICIANS/A/Artist/Second.sid", songIndex: 1)

        store.like(SIDFlowTrackKey(
            sidPath: "/MUSICIANS/A/Artist/First.sid",
            songIndex: 0))
        store.skip(second)
        XCTAssertEqual(store.likedKeys, [first])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("First.sid").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Second.sid").path))
    }

    private func makeManifest(bundleBytes: Int) -> SIDFlowLiteManifest {
        .init(
            schemaVersion: "sidcorr-lite-1",
            generatedAt: "2026-08-18T00:00:00Z",
            corpusVersion: "hvsc",
            hvscVersion: "HVSC Test",
            trackCount: 2,
            fileCount: 2,
            vectorDimensions: 1,
            similarityMetric: "cosine",
            vectorWeights: nil,
            bundleBytes: bundleBytes,
            fileChecksums: .init(bundleSHA256: "test"))
    }

    /// Builds the current published sidcorr-lite-1 shape: codebooks, one
    /// epoch, a plain UTF-8 dictionary, PQ codes, index, and footer.
    private func makeLiteFixture() -> Data {
        var data = Data(repeating: 0, count: 32)
        writeASCII("SIDCORR\u{0}", at: 0, to: &data)
        write16(1, at: 8, to: &data)
        write16(32, at: 10, to: &data)
        write16(1, at: 12, to: &data) // dimensions
        data[14] = 2 // file ID width
        data[15] = 1 // song index width
        write16(1, at: 16, to: &data) // PQ subspaces
        write16(1, at: 18, to: &data) // centroids
        write16(1, at: 20, to: &data) // clusters
        write32(32, at: 24, to: &data) // codebook offset
        write32(48, at: 28, to: &data) // first epoch offset

        // codebook header + one 1.0 float; cluster header + prototype.
        append16(1, to: &data); append16(1, to: &data)
        append32(0x3F80_0000, to: &data)
        append16(1, to: &data); append16(1, to: &data)
        append32(0x3F80_0000, to: &data)
        let epochOffset = data.count

        let first = Array("/MUSICIANS/A/Artist/First.sid".utf8)
        let second = Array("/MUSICIANS/A/Artist/Second.sid".utf8)
        let dictionaryBytes = 2 + first.count + 2 + second.count
        append32(2, to: &data)
        append32(2, to: &data)
        append32(UInt32(dictionaryBytes), to: &data)
        append32(12, to: &data)
        data.append(Data(repeating: 0, count: 24))
        append16(UInt16(first.count), to: &data)
        data.append(contentsOf: first)
        append16(UInt16(second.count), to: &data)
        data.append(contentsOf: second)

        // file ID, subsong index, packed ratings, PQ code
        append16(0, to: &data); data.append(0); append16(0, to: &data); data.append(0)
        append16(1, to: &data); data.append(1); append16(0, to: &data); data.append(0)

        let indexOffset = data.count
        append64(UInt64(epochOffset), to: &data)
        append64(UInt64(40 + dictionaryBytes + 12), to: &data)
        append32(0, to: &data)
        append32(2, to: &data)
        append32(2, to: &data)
        append32(0, to: &data)
        let indexLength = data.count - indexOffset

        append64(UInt64(indexOffset), to: &data)
        append64(UInt64(indexLength), to: &data)
        append32(1, to: &data)
        append32(2, to: &data)
        append32(2, to: &data)
        data.append(Data(repeating: 0, count: 12))
        return data
    }

    private func writeASCII(_ value: String, at offset: Int, to data: inout Data) {
        data.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
    }

    private func write16(_ value: UInt16, at offset: Int, to data: inout Data) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func write32(_ value: UInt32, at offset: Int, to data: inout Data) {
        write16(UInt16(truncatingIfNeeded: value), at: offset, to: &data)
        write16(UInt16(truncatingIfNeeded: value >> 16), at: offset + 2, to: &data)
    }

    private func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func append32(_ value: UInt32, to data: inout Data) {
        append16(UInt16(truncatingIfNeeded: value), to: &data)
        append16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
    }

    private func append64(_ value: UInt64, to data: inout Data) {
        append32(UInt32(truncatingIfNeeded: value), to: &data)
        append32(UInt32(truncatingIfNeeded: value >> 32), to: &data)
    }
}
