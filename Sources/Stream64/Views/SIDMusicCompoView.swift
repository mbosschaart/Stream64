import SwiftUI
import MetalKit

/// Independent video consumer: shares the device's existing stream and SID
/// engine without replacing the main viewer's callback or capture/record hooks.
struct SIDMusicCompoView: View {
    @ObservedObject var model: SIDOscilloscopeViewModel
    @ObservedObject var controller: SIDClubModeController
    @AppStorage("musicCompoVideoOpacity") private var videoOpacity = 0.5
    @AppStorage("sidVisualizationAdaptation") private var adaptation: SIDVisualizationAdaptation = .automatic

    @State private var toolbarVisible = true
    @State private var mouseInside = false
    @State private var cursorHidden = false
    @State private var isAdjustingOpacity = false
    @State private var toolbarHideTask: Task<Void, Never>?

    private func restoreCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    private func stopHidingControls() {
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
        restoreCursor()
        toolbarVisible = true
    }

    private func noteMouseActivity() {
        stopHidingControls()
        guard !isAdjustingOpacity else { return }
        toolbarHideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard !Task.isCancelled else { return }
            toolbarVisible = false
            // NSCursor hiding is app-wide and counted. Own exactly one hide,
            // only while the pointer is inside this active presentation.
            if mouseInside && NSApp.isActive && !cursorHidden {
                NSCursor.hide()
                cursorHidden = true
            }
        }
    }

    var body: some View {
        let presentation = SIDVisualPresentation(channels: model.channels, filters: model.filterStates,
            rhythm: model.kaosRhythm, topology: SIDVisualTopology(
                configuredAddresses: model.configuredSIDAddresses, tuneAddresses: model.tuneSIDAddresses,
                adaptation: adaptation, liveActiveChips: model.liveActiveChips), mode: controller.currentMode, registerActivity: model.registerActivity)
        ZStack(alignment: .bottom) {
            SIDMusicCompoSurface(session: model.session, display: model.session.display,
                input: .snapshot(mode: controller.currentMode, channels: presentation.channels,
                    filters: presentation.filters, rhythm: presentation.rhythm, glow: model.phosphorGlowEnabled),
                videoOpacity: Float(videoOpacity), mode: controller.currentMode,
                channels: presentation.channels, spectrumHistory: model.spectrogramHistory,
                glow: model.phosphorGlowEnabled)
            HStack {
                Text(controller.currentMode.displayName)
                    .lineLimit(1)
                    .help(model.sidLayoutStatus)
                Text("C64 video opacity")
                Slider(value: $videoOpacity, in: 0...1, onEditingChanged: { editing in
                    isAdjustingOpacity = editing
                    noteMouseActivity()
                })
                    .accessibilityLabel("C64 video opacity")
                Text(videoOpacity, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().frame(width: 45, alignment: .trailing)
            }
            .padding(10)
            .background(.bar)
            .opacity(toolbarVisible ? 1 : 0)
            .allowsHitTesting(toolbarVisible)
            .accessibilityHidden(!toolbarVisible)
            .animation(.easeOut(duration: 0.15), value: toolbarVisible)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                mouseInside = true
                noteMouseActivity()
            case .ended:
                mouseInside = false
                noteMouseActivity()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            stopHidingControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopHidingControls()
        }
        .onChange(of: videoOpacity) { _, _ in noteMouseActivity() }
        .onAppear { noteMouseActivity() }
        .onDisappear {
            mouseInside = false
            stopHidingControls()
        }
    }
}

private struct SIDMusicCompoSurface: NSViewRepresentable {
    let session: DeviceSession
    @ObservedObject var display: DisplaySettings
    @ObservedObject private var palettes = PaletteLibrary.shared
    let input: SIDGenerativeUniforms
    let videoOpacity: Float
    let mode: SIDVisualizationMode
    let channels: [SIDVoiceChannel]
    let spectrumHistory: [[Float]]
    let glow: Bool

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        guard let renderer = MetalFrameRenderer(mtkView: view, composedFrames: true),
              let device = view.device,
              let composer = try? SIDMusicCompoComposer(device: device) else {
            let label = NSTextField(labelWithString: "Music Compo Mode requires Metal graphics.")
            label.textColor = .white
            label.frame = CGRect(x: 16, y: 16, width: 400, height: 30)
            view.addSubview(label)
            return view
        }
        context.coordinator.renderer = renderer
        context.coordinator.composer = composer
        renderer.composeFrame = { [weak composer, weak view] command, video, palette in
            guard let view, view.window?.occlusionState.contains(.visible) == true,
                  !view.isHiddenOrHasHiddenAncestor else { return nil }
            return composer?.encode(command: command, video: video, palette: palette)
        }
        // Black until the first UDP frame; no uninitialized source pixels.
        renderer.submitFrame(Data(repeating: 0, count: VideoReceiver.width * VideoReceiver.palHeight))
        context.coordinator.observer = session.videoReceiver.addFrameObserver { [weak renderer] frame in
            renderer?.submitFrame(frame)
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer, let composer = context.coordinator.composer else { return }
        composer.input = input
        composer.performanceScene = SIDPerformanceGPU.Scene(mode: mode)
        composer.channels = channels
        composer.spectrumHistory = spectrumHistory
        composer.videoOpacity = min(1, max(0, videoOpacity))
        composer.selectLogo(SIDLogoAsset.Kind(product: session.reportedProduct))
        renderer.scalingMode = display.scalingMode
        renderer.filterMode = display.filterMode
        renderer.reflectionEnabled = display.bezelReflection
        renderer.signalLevel = display.tubeInput.signalLevel
        renderer.crtScreenColor = display.crtScreenColor
        renderer.crtDirtyGlass = display.crtDirtyGlass
        renderer.monitorDotPitchMillimeters = display.bezelStyle.dotPitchMillimeters
        renderer.picture = display.picture
        renderer.optics = display.optics
        let palette = display.resolvedPalette
        if context.coordinator.palette != palette {
            renderer.setPalette(palette)
            context.coordinator.palette = palette
        }
        view.preferredFramesPerSecond = session.isVideoGPUBehind ? 15 : 30
        renderer.updateAnimationState()
        renderer.requestRedraw()
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        if let observer = coordinator.observer { coordinator.session.videoReceiver.removeFrameObserver(observer) }
        coordinator.renderer?.composeFrame = nil
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
        coordinator.composer = nil
    }

    final class Coordinator {
        let session: DeviceSession
        var renderer: MetalFrameRenderer?
        var composer: SIDMusicCompoComposer?
        var observer: UUID?
        var palette: [SIMD4<UInt8>]?
        init(session: DeviceSession) { self.session = session }
    }
}

/// Every scene renders directly into a GPU texture before video blending and
/// filtering. Per-frame uploads contain numeric SID/audio data only.
final class SIDMusicCompoComposer {
    var input = SIDGenerativeUniforms()
    var performanceScene: SIDPerformanceGPU.Scene?
    var channels: [SIDVoiceChannel] = []
    var spectrumHistory: [[Float]] = []
    private let performance: SIDPerformanceGPU
    var videoOpacity: Float = 0.5
    private let device: MTLDevice
    private let effectPipeline: MTLRenderPipelineState
    private let echoPipeline: MTLRenderPipelineState
    private let blendPipeline: MTLRenderPipelineState
    private var effect: MTLTexture?
    private var output: MTLTexture?
    private var echoHistory: MTLTexture?
    private var logo: MTLTexture
    private var logoKind: SIDLogoAsset.Kind = .c64Ultimate
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var previousMode: Float = -1
    private var motion = SIDPulseVortexVisualization.Motion()

    init(device: MTLDevice) throws {
        self.device = device
        performance = try SIDPerformanceGPU(device: device)
        effectPipeline = try SIDGenerativeRenderer.makePipeline(device: device)
        echoPipeline = try SIDGenerativeRenderer.makePipeline(device: device, feedback: true)
        logo = try SIDLogoAsset.texture(device: device, kind: .c64Ultimate)
        let library = try device.makeLibrary(source: Self.blendSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "compoVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "compoBlend")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        blendPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func selectLogo(_ kind: SIDLogoAsset.Kind) {
        guard kind != logoKind, let texture = try? SIDLogoAsset.texture(device: device, kind: kind) else { return }
        logoKind = kind
        logo = texture
    }

    func encode(command: MTLCommandBuffer, video: MTLTexture, palette: MTLTexture,
                at timestamp: TimeInterval? = nil) -> MTLTexture? {
        if effect?.width != video.width || effect?.height != video.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: video.width, height: video.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            effect = device.makeTexture(descriptor: descriptor)
            output = device.makeTexture(descriptor: descriptor)
            echoHistory = device.makeTexture(descriptor: descriptor)
            previousMode = -1
        }
        guard let effect, let output, let history = echoHistory else { return nil }
        let now = timestamp ?? ProcessInfo.processInfo.systemUptime
        var frame = input
        frame.viewport.x = Float(video.width)
        frame.viewport.y = Float(video.height)
        frame.viewport.z = Float(max(0, now - startedAt))
        let foreground: MTLTexture
        if let performanceScene {
            guard performance.encode(command: command, target: effect, scene: performanceScene,
                input: input, channels: channels, history: spectrumHistory, time: Float(max(0, now-startedAt))) else { return nil }
            foreground = effect
            previousMode = -1
        } else {
            foreground = effect
            let feedback = frame.viewport.w == 6
            if previousMode != frame.viewport.w {
                motion = SIDPulseVortexVisualization.Motion()
                if feedback {
                    guard let encoder = command.makeRenderCommandEncoder(descriptor: Self.pass(history)) else { return nil }
                    encoder.endEncoding()
                }
                previousMode = frame.viewport.w
            }
            if frame.viewport.w == 1 { frame.motion = motion.advance(timestamp: now, input: frame) }
            if feedback { frame.motion.x = Float(min(0.1, max(1.0 / 120, now - lastTime))) }
            lastTime = now
            guard let encoder = command.makeRenderCommandEncoder(descriptor: Self.pass(effect)) else { return nil }
            encoder.setRenderPipelineState(feedback ? echoPipeline : effectPipeline)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<SIDGenerativeUniforms>.stride, index: 0)
            if feedback { encoder.setFragmentTexture(history, index: 0) }
            encoder.setFragmentTexture(logo, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            if feedback, let blit = command.makeBlitCommandEncoder() {
                blit.copy(from: effect, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: effect.width, height: effect.height, depth: 1),
                    to: history, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
        }
        guard let blend = command.makeRenderCommandEncoder(descriptor: Self.pass(output)) else { return nil }
        var opacity = videoOpacity
        blend.setRenderPipelineState(blendPipeline)
        blend.setFragmentTexture(video, index: 0)
        blend.setFragmentTexture(palette, index: 1)
        blend.setFragmentTexture(foreground, index: 2)
        blend.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        blend.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        blend.endEncoding()
        return output
    }

    private static func pass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    static let blendSource = #"""
    #include <metal_stdlib>
    using namespace metal;
    vertex float4 compoVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0, 1);
    }
    fragment float4 compoBlend(float4 p [[position]], texture2d<uint> video [[texture(0)]],
        texture2d<float> palette [[texture(1)]], texture2d<float> effect [[texture(2)]],
        constant float& opacity [[buffer(0)]]) {
        uint2 xy = uint2(p.xy);
        float3 background = palette.read(uint2(video.read(xy).r, 0)).rgb * clamp(opacity, 0.0, 1.0);
        float3 foreground = clamp(effect.read(xy).rgb, 0.0, 1.0);
        return float4(1.0 - (1.0 - foreground) * (1.0 - background), 1);
    }
    """#
}
