import SwiftUI
import MetalKit

/// Direct Metal surface shared by standalone windows and Club Mode.
struct SIDPerformanceGPUView: NSViewRepresentable {
    let scene: SIDPerformanceGPU.Scene
    var input = SIDGenerativeUniforms()
    var channels: [SIDVoiceChannel] = []
    var history: [[Float]] = []
    var underPressure = false

    @AppStorage("sidVisualizationC64Palette") private var c64Palette = false

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        context.coordinator.renderer = Renderer(view: view)
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.c64Palette = c64Palette
        renderer.scene = scene; renderer.input = input
        renderer.channels = channels; renderer.history = history
        renderer.underPressure = underPressure
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true; view.delegate = nil; coordinator.renderer = nil
    }
    final class Coordinator { var renderer: Renderer? }
    final class Renderer: NSObject, MTKViewDelegate {
        let gpu: SIDPerformanceGPU
        let queue: MTLCommandQueue
        let slots = DispatchSemaphore(value: 2)
        let started = ProcessInfo.processInfo.systemUptime
        var scene: SIDPerformanceGPU.Scene = .spectrum
        var input = SIDGenerativeUniforms()
        var channels: [SIDVoiceChannel] = []
        var history: [[Float]] = []
        var c64Palette = false
        private var palettePass: SIDVisualizationPalettePass?
        var underPressure = false
        var lastDraw: TimeInterval = 0
        init?(view: MTKView) {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let gpu = try? SIDPerformanceGPU(device: device) else { return nil }
            self.gpu = gpu; self.queue = queue
            super.init()
            view.device = device; view.colorPixelFormat = .bgra8Unorm
            view.isPaused = true; view.enableSetNeedsDisplay = true
            view.autoResizeDrawable = false; view.delegate = self
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            let now = ProcessInfo.processInfo.systemUptime
            guard view.window?.occlusionState.contains(.visible) == true,
                  !view.isHiddenOrHasHiddenAncestor,
                  now-lastDraw >= (underPressure ? 1.0/15 : 1.0/30),
                  slots.wait(timeout: .now()) == .success else { return }
            var submitted = false
            defer { if !submitted { slots.signal() } }
            let size = SIDGenerativeRenderer.renderSize(for: view.bounds.size, underPressure: underPressure)
            if view.drawableSize != size { view.drawableSize = size }
            guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
            var target = drawable.texture
            if c64Palette {
                if palettePass == nil { palettePass = try? SIDVisualizationPalettePass(device: queue.device) }
                guard let source = palettePass?.sourceTexture(width: Int(size.width), height: Int(size.height)) else { return }
                target = source
            }
            guard gpu.encode(command: command, target: target, scene: scene, input: input,
                channels: channels, history: history, time: Float(now-started)) else { return }
            if c64Palette {
                guard palettePass?.encode(command: command, source: target, target: drawable.texture) == true else { return }
            }
            command.present(drawable)
            let semaphore = slots
            command.addCompletedHandler { _ in semaphore.signal() }
            submitted = true; lastDraw = now
            command.commit()
        }
    }
}

extension SIDPerformanceGPU.Scene {
    init?(mode: SIDVisualizationMode) {
        switch mode {
        case .spectrum: self = .spectrum
        case .barField3D: self = .barField
        case .colorfulWaveform: self = .waveform
        case .sidShowcase: self = .showcase
        case .waterfall3D: self = .waterfall
        case .spectrogram: self = .spectrogram
        default: return nil
        }
    }
}
