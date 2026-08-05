import SwiftUI

struct UpdateSheet: View {
    @EnvironmentObject var updater: UpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Stream64 Updates", systemImage: "arrow.down.circle")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { updater.dismiss() }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(width: 520, height: 360)
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
            releaseDetails(release)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Update unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Try Again") { updater.check(force: true) }
                    Spacer()
                    Button("Close") { updater.dismiss() }
                }
            }
        }
    }

    private func releaseDetails(
        _ release: Stream64Release
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
                Button("Open GitHub Release") {
                    updater.openReleasePage(release)
                }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Cancel") { updater.dismiss() }
            }
        }
    }
}
