import XCTest
import CryptoKit
@testable import Stream64

final class HVSCExtractorIntegrityTests: XCTestCase {
    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    func testSignedExtractorAcceptsRecordedDigestAndRejectsTampering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Fixture.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Stream64/Resources/hvsc-7zz")
        let helper = resources.appendingPathComponent("hvsc-7zz")
        try FileManager.default.copyItem(at: source, to: helper)
        let upstream = try digest(helper)
        try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", helper.path])
        let signed = try digest(helper)
        XCTAssertNotEqual(upstream, signed, "Signing must exercise the changed-binary regression")
        let input = root.appendingPathComponent("Tune.sid")
        let payload = Data("HVSC extraction integrity fixture".utf8)
        try payload.write(to: input)
        let archive = root.appendingPathComponent("Fixture.7z")
        try run(helper, ["a", archive.path, input.path])
        let plist: [String: Any] = ["CFBundleIdentifier": "test.stream64.extractor", "CFBundlePackageType": "APPL",
                                   "HVSC7zSHA256": signed]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Fixture.app")))
        let extractor = BundledSigned7zExtractor(resourceBundle: bundle)
        let entries = try await extractor.inspect(archive: archive)
        XCTAssertTrue(entries.contains { $0.path == "Tune.sid" })
        let output = root.appendingPathComponent("extracted")
        try await extractor.extract(archive: archive, to: output, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Tune.sid")), payload)
        var modified = try Data(contentsOf: helper); modified.append(0)
        try modified.write(to: helper)
        do {
            _ = try await extractor.inspect(archive: archive)
            XCTFail("A modified extractor must still be rejected")
        } catch HVSCExtractorError.untrustedExtractor { }
    }
    func testReleasedBuild133ReproducesMismatchWhenAvailable() async throws {
        guard let path = ProcessInfo.processInfo.environment["STREAM64_OLD_RELEASE_APP"] else {
            throw XCTSkip("Set STREAM64_OLD_RELEASE_APP to reproduce the original signed release failure")
        }
        let bundle = try XCTUnwrap(Bundle(url: URL(fileURLWithPath: path)))
        do {
            _ = try await BundledSigned7zExtractor(resourceBundle: bundle).inspect(
                archive: URL(fileURLWithPath: "/tmp/nonexistent.7z"))
            XCTFail("Original build should reject the helper before reading an archive")
        } catch HVSCExtractorError.untrustedExtractor { }
    }
}
