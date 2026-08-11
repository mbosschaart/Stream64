import AppKit
import CryptoKit
import Foundation
import ZIPFoundation

protocol UpdateHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UpdateHTTPTransport {}

struct Stream64ReleaseAsset: Decodable, Identifiable {
    let name: String
    let browserDownloadURL: URL
    let size: Int?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

struct Stream64Release: Decodable, Identifiable {
    let tagName: String
    let name: String
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Stream64ReleaseAsset]

    var id: String { tagName }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

struct Stream64ReleaseVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let suffix: String

    init?(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parts = normalized.split(separator: ".", maxSplits: 2)
        guard parts.count >= 2,
              let major = Int(parts[0]) else { return nil }

        let minorAndSuffix = String(parts[1])
        let digits = minorAndSuffix.prefix { $0.isNumber }
        guard !digits.isEmpty, let minor = Int(digits) else { return nil }

        var patch = 0
        var suffix = String(minorAndSuffix.dropFirst(digits.count))
        if parts.count == 3 {
            let patchAndSuffix = String(parts[2])
            let patchDigits = patchAndSuffix.prefix { $0.isNumber }
            guard !patchDigits.isEmpty, let parsedPatch = Int(patchDigits) else {
                return nil
            }
            patch = parsedPatch
            suffix = String(patchAndSuffix.dropFirst(patchDigits.count))
        }
        guard suffix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix.lowercased()
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A plain version is newer than a suffixed beta version.
        if lhs.suffix.isEmpty != rhs.suffix.isEmpty {
            return !lhs.suffix.isEmpty
        }
        return lhs.suffix.localizedStandardCompare(rhs.suffix) == .orderedAscending
    }
}

enum UpdateState {
    case idle
    case checking
    case upToDate
    case available(Stream64Release)
    case downloading(Stream64Release)
    case ready(Stream64Release, URL)
    case installing
    case failed(String)
}

@MainActor
final class UpdateService: ObservableObject {
    static let repositoryURL = URL(
        string: "https://api.github.com/repos/mbosschaart/Stream64/releases/latest")!
    nonisolated static let fallbackTeamIdentifier = "EJ77LX9A8T"

    @Published private(set) var state: UpdateState = .idle
    @Published var isPresented = false
    @Published private(set) var preparedArchiveURL: URL?
    /// Last release associated with the current update flow (for GitHub fallback after failure).
    @Published private(set) var lastRelease: Stream64Release?

    private let transport: any UpdateHTTPTransport
    private var activeTask: Task<Void, Never>?
    private var automaticCheckStarted = false
    private var preparedDirectory: URL?
    private let defaults: UserDefaults

    init(
        transport: any UpdateHTTPTransport = URLSession.shared,
        defaults: UserDefaults = .standard
    ) {
        self.transport = transport
        self.defaults = defaults
    }

    deinit {
        activeTask?.cancel()
    }

    func checkAutomatically() {
        guard !automaticCheckStarted else { return }
        automaticCheckStarted = true
        let enabled = defaults.object(
            forKey: "checkForUpdatesAutomatically") as? Bool ?? true
        guard enabled else { return }
        check(force: false)
    }

    func check(force: Bool) {
        guard activeTask == nil else { return }
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.performCheck(force: force)
            self.activeTask = nil
        }
    }

    func downloadAndPrepare(_ release: Stream64Release) {
        guard activeTask == nil else { return }
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.performDownload(release)
            self.activeTask = nil
        }
    }

    func installPreparedUpdate(release: Stream64Release, archiveURL: URL) {
        guard activeTask == nil else { return }
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.performInstall(release: release, archiveURL: archiveURL)
            self.activeTask = nil
        }
    }

    func openReleasePage(_ release: Stream64Release) {
        NSWorkspace.shared.open(release.htmlURL)
    }

    func revealDownload(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealPreparedDownload() {
        guard let preparedArchiveURL else { return }
        revealDownload(preparedArchiveURL)
    }

    func dismiss() {
        isPresented = false
        if case .upToDate = state { state = .idle }
    }

    static func asset(
        named name: String,
        in release: Stream64Release
    ) -> Stream64ReleaseAsset? {
        release.assets.first { $0.name == name }
    }

    nonisolated static func assetNames(
        tagName: String,
        architecture: String
    ) -> (archive: String, checksum: String) {
        let version = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let archive = "Stream64-\(version)-macos-\(architecture).zip"
        return (
            archive,
            "\(archive.replacingOccurrences(of: ".zip", with: ""))-SHA256.txt"
        )
    }

    static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }

    private func performCheck(force: Bool) async {
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            guard let latest = Stream64ReleaseVersion(release.tagName),
                  let current = Stream64ReleaseVersion(Stream64Version.display) else {
                throw UpdateError.invalidVersion
            }
            guard latest > current else {
                state = .upToDate
                if force { isPresented = true }
                return
            }

            let offeredKey = "lastOfferedUpdateVersion"
            if !force, defaults.string(forKey: offeredKey) == release.tagName {
                state = .idle
                return
            }
            defaults.set(release.tagName, forKey: offeredKey)
            lastRelease = release
            state = .available(release)
            isPresented = true
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
            if force { isPresented = true }
        }
    }

    private func fetchLatestRelease() async throws -> Stream64Release {
        var request = URLRequest(url: Self.repositoryURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Stream64/\(Stream64Version.display)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw UpdateError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let release = try JSONDecoder().decode(Stream64Release.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw UpdateError.noStableRelease
        }
        return release
    }

    private func performDownload(_ release: Stream64Release) async {
        lastRelease = release
        state = .downloading(release)
        do {
            let architecture = Self.architectureName
            guard architecture != "unsupported" else {
                throw UpdateError.unsupportedArchitecture
            }
            let names = Self.assetNames(
                tagName: release.tagName, architecture: architecture)
            guard let archiveAsset = Self.asset(named: names.archive, in: release),
                  let checksumAsset = Self.asset(named: names.checksum, in: release) else {
                throw UpdateError.missingAsset(names.archive)
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Stream64Update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            preparedDirectory = directory
            let archiveURL = directory.appendingPathComponent(archiveAsset.name)
            let checksumURL = directory.appendingPathComponent(checksumAsset.name)
            try await download(archiveAsset.browserDownloadURL, to: archiveURL)
            try await download(checksumAsset.browserDownloadURL, to: checksumURL)
            try Self.verifyChecksum(
                archiveData: try Data(contentsOf: archiveURL),
                archiveName: archiveURL.lastPathComponent,
                checksumData: try Data(contentsOf: checksumURL))
            preparedArchiveURL = archiveURL
            lastRelease = release
            state = .ready(release, archiveURL)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
            isPresented = true
        }
    }

    private func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Stream64/\(Stream64Version.display)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw UpdateError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try data.write(to: destination, options: .atomic)
    }

    nonisolated static func verifyChecksum(
        archiveData: Data,
        archiveName: String,
        checksumData: Data
    ) throws {
        guard let checksumText = String(data: checksumData, encoding: .utf8) else {
            throw UpdateError.invalidChecksum
        }
        let expected = checksumText
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2,
                      String(fields[1]).hasSuffix(archiveName) else {
                    return nil
                }
                return String(fields[0]).lowercased()
            }
            .first
        guard let expected, expected.count == 64 else {
            throw UpdateError.invalidChecksum
        }
        let digest = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expected else { throw UpdateError.checksumMismatch }
    }

    private func performInstall(release: Stream64Release, archiveURL: URL) async {
        state = .installing
        do {
            let currentApp = Bundle.main.bundleURL
            guard currentApp.pathExtension == "app",
                  FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path) else {
                throw UpdateError.appNotWritable
            }
            let extractionDirectory = preparedDirectory
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("Stream64Install-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: extractionDirectory, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: archiveURL, to: extractionDirectory)
            guard let replacement = try FileManager.default
                .contentsOfDirectory(at: extractionDirectory, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.appMissingFromArchive
            }

            try Self.verifyTeamIdentifier(of: replacement)
            Self.clearQuarantine(at: replacement)

            // Keep the original item's Finder/TCC-facing metadata when
            // swapping the bundle contents. `.usingNewMetadataOnly` made
            // each update look like a brand-new app to Local Network
            // privacy, so discovery permission was lost after install.
            // Delete the temporary backup immediately — leftover
            // `.Stream64-backup-*.app` bundles also accumulate as stale
            // Local Network entries.
            let backupName = ".Stream64-backup-\(UUID().uuidString).app"
            let parent = currentApp.deletingLastPathComponent()
            let backupURL = parent.appendingPathComponent(backupName)
            _ = try FileManager.default.replaceItemAt(
                currentApp, withItemAt: replacement, backupItemName: backupName)
            try? FileManager.default.removeItem(at: backupURL)
            Self.removeStaleUpdateBackups(in: parent, keeping: backupURL)
            NSWorkspace.shared.open(currentApp)
            NSApp.terminate(nil)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
            isPresented = true
        }
    }

    nonisolated static func expectedTeamIdentifier() -> String {
        if let fromInfo = Bundle.main.object(forInfoDictionaryKey: "TeamIdentifier") as? String,
           !fromInfo.isEmpty {
            return fromInfo
        }
        if let fromCodesign = try? teamIdentifier(of: Bundle.main.bundleURL),
           !fromCodesign.isEmpty {
            return fromCodesign
        }
        return fallbackTeamIdentifier
    }

    nonisolated static func teamIdentifier(of appURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--verbose=4", appURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError.untrustedSignature
        }
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasPrefix("TeamIdentifier=") {
                let value = String(text.dropFirst("TeamIdentifier=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value != "not set" else {
                    throw UpdateError.untrustedSignature
                }
                return value
            }
        }
        throw UpdateError.untrustedSignature
    }

    nonisolated static func verifyTeamIdentifier(of appURL: URL) throws {
        let actual = try teamIdentifier(of: appURL)
        guard actual == expectedTeamIdentifier() else {
            throw UpdateError.untrustedSignature
        }
    }

    nonisolated static func clearQuarantine(at appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Removes leftover `.Stream64-backup-*.app` bundles from earlier updates.
    /// Backups use a leading '.' so enumeration must include hidden items.
    nonisolated static func removeStaleUpdateBackups(
        in directory: URL,
        keeping currentBackup: URL? = nil
    ) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(".Stream64-backup-"),
                  name.hasSuffix(".app"),
                  url != currentBackup else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum UpdateError: LocalizedError {
    case invalidVersion
    case noStableRelease
    case httpStatus(Int)
    case unsupportedArchitecture
    case missingAsset(String)
    case invalidChecksum
    case checksumMismatch
    case untrustedSignature
    case appNotWritable
    case appMissingFromArchive

    var errorDescription: String? {
        switch self {
        case .invalidVersion: return "Stream64 or the GitHub release has an invalid version."
        case .noStableRelease: return "No stable Stream64 release is available."
        case .httpStatus(let status): return "GitHub returned HTTP status \(status)."
        case .unsupportedArchitecture: return "This Mac architecture is not supported by the release."
        case .missingAsset(let name): return "The release is missing its \(name) download."
        case .invalidChecksum: return "The release checksum file is invalid."
        case .checksumMismatch: return "The downloaded update failed checksum verification."
        case .untrustedSignature:
            return "The downloaded update is not signed by the Stream64 developer team."
        case .appNotWritable:
            return "Stream64 cannot replace itself in its current location."
        case .appMissingFromArchive:
            return "The downloaded archive does not contain a Stream64 app."
        }
    }
}
