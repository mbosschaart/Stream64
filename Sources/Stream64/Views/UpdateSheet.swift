import SwiftUI

struct UpdateSheet: View {
    @EnvironmentObject var updater: UpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Stream64 Updates", systemImage: "arrow.down.circle")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !isInstalling {
                    Button("Close") { updater.dismiss() }
                }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(width: 520, height: 360)
        .interactiveDismissDisabled(isInstalling)
    }

    private var isInstalling: Bool {
        if case .installing = updater.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .idle:
            ProgressView("Preparing update check…")
        case .checking:
            ProgressView("Checking GitHub for the latest stable release…")
        case .upToDate:
            ContentUnavailableView(
                "You’re up to date",
                systemImage: "checkmark.circle",
                description: Text("Stream64 \(Stream64Version.display) is the latest stable release."))
        case .available(let release):
            releaseDetails(release, buttonTitle: "Download Update") {
                updater.downloadAndPrepare(release)
            }
        case .downloading(let release):
            releaseDetails(release, buttonTitle: "Downloading…") {
            }
        case .ready(let release, let archiveURL):
            releaseDetails(release, buttonTitle: "Install and Relaunch") {
                updater.installPreparedUpdate(release: release, archiveURL: archiveURL)
            }
        case .installing:
            ProgressView("Installing update and relaunching Stream64…")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Update unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Try Again") { updater.check(force: true) }
                    if let release = updater.lastRelease {
                        Button("Open GitHub Release") {
                            updater.openReleasePage(release)
                        }
                    }
                    if updater.preparedArchiveURL != nil {
                        Button("Show Download") {
                            updater.revealPreparedDownload()
                        }
                    }
                    Spacer()
                    Button("Close") { updater.dismiss() }
                }
            }
        }
    }

    private func releaseDetails(
        _ release: Stream64Release,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(release.name) is available")
                .font(.headline)
            Text("Current version: \(Stream64Version.display)")
                .foregroundStyle(.secondary)
            if let body = release.body, !body.isEmpty {
                ScrollView {
                    Text(body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 170)
            }
            HStack {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(buttonTitle == "Downloading…")
                Button("Open GitHub Release") {
                    updater.openReleasePage(release)
                }
                if case .ready = updater.state {
                    Text("Checksum verified")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { updater.dismiss() }
            }
        }
    }
}
