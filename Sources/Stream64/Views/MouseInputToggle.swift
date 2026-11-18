import SwiftUI

/// Low-frequency input observation stays separate from the video host.
struct MouseInputToggle: View {
    @ObservedObject var input: InputSettings

    var body: some View {
        Toggle(isOn: $input.mouseEnabled) {
            Label("Mouse Input", systemImage: "computermouse")
        }
        .disabled(!input.mouseAvailable || input.capability != .supported || input.transport == .legacy)
        .help("Remote mouse requires C64 Ultimate firmware 1.2.1+. Click the viewer to control it; Escape turns it off. Option-right-click opens the menu.")
    }
}
