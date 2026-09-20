import SwiftUI
import MetalKit

/// Uses the existing per-window engine mirror; no independent timers, audio
/// taps, debug leases or high-frequency observations on the context-menu host.
struct SIDGenerativeView: NSViewRepresentable {
    let mode: SIDVisualizationMode
    let channels: [SIDVoiceChannel]
    let filters: [SIDFilterRegisters]
    let rhythm: KAOSRhythmState
    let glow: Bool
    var logoKind: SIDLogoAsset.Kind = .c64Ultimate
    var videoGPUBehind: () -> Bool

    @AppStorage("sidVisualizationC64Palette") private var c64Palette = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        context.coordinator.renderer = SIDGenerativeRenderer(view: view)
        if context.coordinator.renderer == nil {
            let label = NSTextField(labelWithString: "This visualization requires Metal graphics.")
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        }
        view.setAccessibilityLabel(mode.displayName + " SID visualization")
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.c64Palette = c64Palette
        renderer.uniforms = .snapshot(mode: mode, channels: channels,
                                     filters: filters, rhythm: rhythm, glow: glow)
        renderer.selectLogo(logoKind)
        renderer.videoGPUBehind = videoGPUBehind
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
    }

    final class Coordinator {
        var renderer: SIDGenerativeRenderer?
    }
}
