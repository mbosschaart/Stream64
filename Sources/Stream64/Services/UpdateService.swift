import AppKit
import Foundation

protocol UpdateHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UpdateHTTPTransport {}

struct Stream64Release: Decodable, Identifiable {
    let tagName: String
    let name: String
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    var id: String { tagName }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
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
    case failed(String)
}

@MainActor
final class UpdateService: ObservableObject {
    static let repositoryURL = URL(
        string: "https://api.github.com/repos/mbosschaart/Stream64/releases/latest")!

    @Published private(set) var state: UpdateState = .idle
    @Published var isPresented = false

    private let transport: any UpdateHTTPTransport
    private var activeTask: Task<Void, Never>?
    private var automaticCheckStarted = false
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

    func openReleasePage(_ release: Stream64Release) {
        NSWorkspace.shared.open(release.htmlURL)
    }

    func dismiss() {
        isPresented = false
        if case .upToDate = state { state = .idle }
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

}

enum UpdateError: LocalizedError {
    case invalidVersion
    case noStableRelease
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidVersion: return "Stream64 or the GitHub release has an invalid version."
        case .noStableRelease: return "No stable Stream64 release is available."
        case .httpStatus(let status): return "GitHub returned HTTP status \(status)."
        }
    }
}
