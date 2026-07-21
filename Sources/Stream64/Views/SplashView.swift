import SwiftUI

struct SplashView: View {
    var body: some View {
        VStack(spacing: 18) {
            if let logo = Stream64Assets.applicationIcon {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 330, height: 330)
                    .accessibilityLabel("Stream64")
            }

            Text("Version \(Stream64Version.display)")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(width: 440, height: 440)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
