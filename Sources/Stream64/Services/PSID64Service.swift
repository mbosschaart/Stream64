import AppKit
import Foundation

/// User-approved bridge to the upstream PSID64 command-line converter.
/// The GPL tool is never bundled with Stream64; it is fetched from its
/// publisher only after an explicit first-use confirmation.
@MainActor
final class PSID64Service {
    static let releaseURL = URL(
        string: "https://github.com/hermansr/psid64/releases/download/v1.3/psid64-1.3.dmg")!
    static let projectURL = URL(string: "https://psid64.sourceforge.io/")!
    static let sourceURL = URL(string: "https://github.com/hermansr/psid64")!

    enum ServiceError: LocalizedError {
        case installationDeclined
        case invalidExecutable
        case conversionFailed(String)
        case invalidPRG

        var errorDescription: String? {
            switch self {
            case .installationDeclined:
                return "PSID playback requires PSID64 conversion. Installation was cancelled."
            case .invalidExecutable:
                return "PSID64 could not run on this Mac. Its v1.3 macOS release may require Rosetta."
            case .conversionFailed(let message):
                return "PSID64 conversion failed: \(message)"
            case .invalidPRG:
                return "PSID64 did not produce a valid C64 PRG."
            }
        }
    }

    private var executableURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Stream64", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("psid64", isDirectory: false)
    }

    func convert(_ sid: Data, filename: String) async throws -> Data {
        let executable = try await resolveExecutable()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stream64-PSID64-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent(filename)
        let output = directory.appendingPathComponent("converted.prg")
        try sid.write(to: input, options: .atomic)
        let result = try run(
            executable,
            arguments: Self.conversionArguments(output: output, input: input))
        guard result.status == 0 else {
            throw ServiceError.conversionFailed(result.output)
        }
        let prg = try Data(contentsOf: output)
        guard Self.isValidPRG(prg) else { throw ServiceError.invalidPRG }
        return prg
    }

    nonisolated static func conversionArguments(output: URL, input: URL) -> [String] {
        ["--output", output.path, input.path]
    }

    nonisolated static func isValidPRG(_ data: Data) -> Bool {
        data.count > 2
    }

    func installedVersion() -> String? {
        executableVersion(at: executableURL)
    }

    private func executableVersion(at url: URL) -> String? {
        guard let result = try? run(url, arguments: ["--version"]),
              result.status == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var installationPath: String { executableURL.path }

    func removeInstalledTool() throws {
        guard FileManager.default.fileExists(atPath: executableURL.path) else { return }
        try FileManager.default.removeItem(at: executableURL)
    }

    private func resolveExecutable() async throws -> URL {
        if installedVersion() != nil { return executableURL }
        switch presentInstallPrompt() {
        case .install:
            try await installFromUpstream()
        case .choose:
            try chooseExecutable()
        case .cancel:
            throw ServiceError.installationDeclined
        }
        guard installedVersion() != nil else { throw ServiceError.invalidExecutable }
        return executableURL
    }

    private enum InstallChoice { case install, choose, cancel }

    private func presentInstallPrompt() -> InstallChoice {
        let alert = NSAlert()
        alert.messageText = "Install PSID64 for PSID Playback?"
        alert.informativeText = """
        PSID64 converts PSID files into C64 PRGs with a relocated driver, improving real-C64 compatibility. It cannot fix missing or mismatched SID hardware and has memory/timing limitations.

        Stream64 will download PSID64 v1.3 from its official GitHub release. PSID64 is GPL-2.0-or-later; project and source links are available in Settings after installation.
        """
        alert.addButton(withTitle: "Install PSID64")
        alert.addButton(withTitle: "Choose Executable…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .install
        case .alertSecondButtonReturn: return .choose
        default: return .cancel
        }
    }

    private func chooseExecutable() throws {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PSID64 executable"
        guard panel.runModal() == .OK, let source = panel.url else {
            throw ServiceError.installationDeclined
        }
        try install(executableAt: source)
    }

    private func installFromUpstream() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stream64-PSID64-Install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dmg = directory.appendingPathComponent("psid64-1.3.dmg")
        let (data, response) = try await URLSession.shared.data(from: Self.releaseURL)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw ServiceError.conversionFailed("official download returned an unexpected response")
        }
        try data.write(to: dmg, options: .atomic)
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { _ = try? run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", mount.path]) }
        let attached = try run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        guard attached.status == 0,
              let executable = FileManager.default.enumerator(
                at: mount,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])?
                .compactMap({ $0 as? URL })
                .first(where: { $0.lastPathComponent == "psid64" })
        else {
            throw ServiceError.invalidExecutable
        }
        try install(executableAt: executable)
    }

    private func install(executableAt source: URL) throws {
        let fileManager = FileManager.default
        let directory = executableURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let candidate = directory.appendingPathComponent(
            ".psid64-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: candidate) }
        try fileManager.copyItem(at: source, to: candidate)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: candidate.path)
        guard executableVersion(at: candidate) != nil else {
            throw ServiceError.invalidExecutable
        }
        if fileManager.fileExists(atPath: executableURL.path) {
            _ = try fileManager.replaceItemAt(
                executableURL, withItemAt: candidate,
                backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: candidate, to: executableURL)
        }
    }

    private func run(
        _ executable: URL,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }
}
