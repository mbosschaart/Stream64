import XCTest
import CryptoKit
import ZIPFoundation
import MetalKit
import AVFoundation
@testable import Stream64

final class UpdateTests: XCTestCase {
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


    func testUpdateServiceExpectedTeamIdentifierFallback() {
        XCTAssertEqual(UpdateService.fallbackTeamIdentifier, "EJ77LX9A8T")
        XCTAssertFalse(UpdateService.expectedTeamIdentifier().isEmpty)
    }


    func testUpdateRelaunchShellQuoteEscapesEmbeddedQuotes() {
        XCTAssertEqual(
            UpdateService.shellQuote("/Applications/Stream64.app"),
            "'/Applications/Stream64.app'")
        XCTAssertEqual(
            UpdateService.shellQuote("/tmp/O'Brien/Stream64.app"),
            "'/tmp/O'\\''Brien/Stream64.app'")
    }


    func testUpdateInstallReplacementMovesAppIntoPlace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stream64InstallTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let current = root.appendingPathComponent("Stream64.app", isDirectory: true)
        let replacement = root.appendingPathComponent("Stream64-new.app", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("marker.txt"))
        try Data("new".utf8).write(to: replacement.appendingPathComponent("marker.txt"))

        try UpdateService.installReplacement(replacement, over: current)

        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("marker.txt"), encoding: .utf8),
            "new")
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".Stream64-backup-") }
        XCTAssertTrue(leftovers.isEmpty)
    }


}
