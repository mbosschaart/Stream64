import SwiftUI

struct AboutView: View {
    private let shopURL = URL(string: "https://www.retro8bitshop.com")!

    var body: some View {
        VStack(spacing: 18) {
            if let logo = Stream64Assets.aboutLogo {
                Image(nsImage: logo)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 420)
                    .accessibilityLabel("Retro8BITShop")
            }

            VStack(spacing: 5) {
                Text("Stream64")
                    .font(.title.bold())
                Text("Version \(Stream64Version.display)")
                    .foregroundStyle(.secondary)
            }

            Text("Built for the community. Commodore forever!")
                .font(.headline)

            Link("https://www.retro8bitshop.com", destination: shopURL)

            Text("Designed by Martijn Bosschaart 2026")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("PolyForm Noncommercial License 1.0.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(width: 520, height: 320)
    }
}
