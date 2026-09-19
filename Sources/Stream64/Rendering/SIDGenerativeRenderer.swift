import MetalKit

/// SIMD-only layout mirrored by the Metal uniform block. No buffers or audio
/// processing are shared between windows; each draw copies a small snapshot.
struct SIDGenerativeUniforms {
    var viewport = SIMD4<Float>(640, 360, 0, 0) // width, height, time, mode
    var energy = SIMD4<Float>.zero // bass, mid, impact, master
    var style = SIMD4<Float>(0, 0, 3, 0) // cutoff, resonance, voice count, glow
    var rhythm = SIMD4<Float>.zero // confident beat pulse, impact strength, beat phase, confidence
    var motion = SIMD4<Float>.zero // effect-owned travel, rotation, shock age, punch
    var voice0 = SIMD4<Float>.zero // envelope, normalized pitch, pulse width, noise
    var voice1 = SIMD4<Float>.zero
    var voice2 = SIMD4<Float>.zero
    var voice3 = SIMD4<Float>.zero
    var voice4 = SIMD4<Float>.zero
    var voice5 = SIMD4<Float>.zero
    var voice6 = SIMD4<Float>.zero
    var voice7 = SIMD4<Float>.zero
    var voice8 = SIMD4<Float>.zero

    static func snapshot(
        mode: SIDVisualizationMode, channels: [SIDVoiceChannel],
        filters: [SIDFilterRegisters], rhythm: KAOSRhythmState, glow: Bool
    ) -> Self {
        func unit(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
        var result = Self()
        switch mode {
        case .blackhole: result.viewport.w = 1
        case .arrowVectorField: result.viewport.w = 2
        case .sea: result.viewport.w = 3
        case .pixelRiptide: result.viewport.w = 4
        case .pulseRibbons: result.viewport.w = 5
        case .echoTunnel: result.viewport.w = 6
        case .neonOrbit: result.viewport.w = 7
        case .shardStorm: result.viewport.w = 8
        case .grainNebula: result.viewport.w = 9
        case .dotMatrix: result.viewport.w = 10
        case .signalCollage: result.viewport.w = 11
        default: break
        }
        result.energy = SIMD4(unit(rhythm.bassEnergy), unit(rhythm.midEnergy),
                              unit(rhythm.impactPulse), unit(rhythm.masterLevel))
        result.rhythm = SIMD4(unit(rhythm.beatPulse * rhythm.beatConfidence * rhythm.masterLevel),
                              unit(rhythm.impactStrength), unit(rhythm.beatPhase), unit(rhythm.beatConfidence))
        let count = min(9, max(3, ((channels.map(\.chipIndex).max() ?? 0) + 1) * 3))
        result.style = SIMD4(
            unit(Float(filters.map(\.cutoffValue).max() ?? 0) / 2047),
            unit(Float(filters.map(\.resonance).max() ?? 0) / 15),
            Float(count), glow ? 1 : 0)
        var voices = Array(repeating: SIMD4<Float>.zero, count: 9)
        for channel in channels where (0..<9).contains(channel.id) {
            let chip = filters.indices.contains(channel.chipIndex) ? filters[channel.chipIndex] : nil
            let muted = channel.registers.test || (channel.voiceIndex == 2 && chip?.voice3Disconnected == true)
            let volume = Float(chip?.volume ?? 15) / 15
            voices[channel.id] = SIMD4(
                muted ? 0 : unit(Float(channel.synth.envelope) * volume),
                unit(Float(log2(max(20, channel.frequencyHz) / 20) / 10)),
                unit(Float(channel.registers.pulseWidth) / 4095),
                channel.registers.noiseEnabled ? 1 : 0)
        }
        result.voice0 = voices[0]; result.voice1 = voices[1]; result.voice2 = voices[2]
        result.voice3 = voices[3]; result.voice4 = voices[4]; result.voice5 = voices[5]
        result.voice6 = voices[6]; result.voice7 = voices[7]; result.voice8 = voices[8]
        return result
    }
}

/// Draws only when the shared SID engine supplies a visible-window snapshot.
/// A bounded render size, nonblocking GPU slots and a 15 Hz pressure fallback
/// keep these auxiliary windows subordinate to the main C64 video renderer.
final class SIDGenerativeRenderer: NSObject, MTKViewDelegate {
    static let maximumRenderDimension: CGFloat = 1000
    private var logoTexture: MTLTexture
    private var logoKind: SIDLogoAsset.Kind = .c64Ultimate
    private let pipeline: MTLRenderPipelineState
    private let echoPipeline: MTLRenderPipelineState
    private var echoHistory: MTLTexture?
    private let queue: MTLCommandQueue
    private let slots = DispatchSemaphore(value: 2)
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastDraw: TimeInterval = 0
    private var blackholeMotion = SIDPulseVortexVisualization.Motion()
    var uniforms = SIDGenerativeUniforms()
    var videoGPUBehind: () -> Bool = { false }

    static func makePipeline(device: MTLDevice, feedback: Bool = false,
                             library suppliedLibrary: MTLLibrary? = nil) throws -> MTLRenderPipelineState {
        let library = try suppliedLibrary ?? device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sidVisualVertex")
        descriptor.fragmentFunction = library.makeFunction(name: feedback ? "sidEchoFragment" : "sidVisualFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // Club can remount a scene every 200 ms. Reuse immutable pipelines so
    // shader compilation never repeats on those cuts; motion/history stay local.
    private static let pipelineLock = NSLock()
    private static var cachedPipelines: [UInt64: (MTLRenderPipelineState, MTLRenderPipelineState)] = [:]

    private static func pipelines(for device: MTLDevice) throws -> (MTLRenderPipelineState, MTLRenderPipelineState) {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let cached = cachedPipelines[device.registryID] { return cached }
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let result = (try makePipeline(device: device, library: library),
                      try makePipeline(device: device, feedback: true, library: library))
        cachedPipelines[device.registryID] = result
        return result
    }

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let logoTexture = try? SIDLogoAsset.texture(device: device),
              let queue = device.makeCommandQueue(),
              let pipelines = try? Self.pipelines(for: device) else { return nil }
        self.logoTexture = logoTexture
        self.queue = queue
        self.pipeline = pipelines.0
        self.echoPipeline = pipelines.1
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = false
        view.delegate = self
    }

    func selectLogo(_ kind: SIDLogoAsset.Kind) {
        guard kind != logoKind,
              let texture = try? SIDLogoAsset.texture(device: logoTexture.device, kind: kind) else { return }
        logoTexture = texture
        logoKind = kind
    }

    static func renderSize(for size: CGSize, underPressure: Bool) -> CGSize {
        let limit: CGFloat = underPressure ? 640 : maximumRenderDimension
        let scale = min(1, limit / max(1, max(size.width, size.height)))
        return CGSize(width: max(1, (size.width * scale).rounded()),
                      height: max(1, (size.height * scale).rounded()))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let window = view.window, window.occlusionState.contains(.visible),
              !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0,
              view.bounds.height > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let behind = videoGPUBehind()
        guard now - lastDraw >= (behind ? 1.0 / 15 : 1.0 / 30),
              slots.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { slots.signal() } }
        let size = Self.renderSize(for: view.bounds.size, underPressure: behind)
        if view.drawableSize != size { view.drawableSize = size }
        // Only temporal feedback requires a readable drawable for the history copy.
        view.framebufferOnly = uniforms.viewport.w != 6
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].storeAction = .store
        let feedback = uniforms.viewport.w == 6
        if feedback {
            if echoHistory?.width != Int(size.width) || echoHistory?.height != Int(size.height) {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: Int(size.width), height: Int(size.height), mipmapped: false)
                descriptor.usage = [.shaderRead, .renderTarget]
                descriptor.storageMode = .private
                guard let texture = view.device?.makeTexture(descriptor: descriptor) else { return }
                let clear = MTLRenderPassDescriptor()
                clear.colorAttachments[0].texture = texture
                clear.colorAttachments[0].loadAction = .clear
                clear.colorAttachments[0].storeAction = .store
                guard let clearEncoder = command.makeRenderCommandEncoder(descriptor: clear) else { return }
                clearEncoder.endEncoding()
                echoHistory = texture
            }
        } else {
            echoHistory = nil
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var frame = uniforms
        frame.viewport.x = Float(size.width)
        frame.viewport.y = Float(size.height)
        frame.viewport.z = Float(now - startedAt)
        if frame.viewport.w == 1 {
            frame.motion = blackholeMotion.advance(timestamp: now, input: frame)
        }
        if feedback {
            frame.motion.x = Float(min(0.1, max(1.0 / 120, now - lastDraw)))
            encoder.setFragmentTexture(echoHistory, index: 0)
        }
        encoder.setFragmentTexture(logoTexture, index: 1)
        encoder.setRenderPipelineState(feedback ? echoPipeline : pipeline)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<SIDGenerativeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if feedback, let history = echoHistory {
            guard let blit = command.makeBlitCommandEncoder() else { return }
            blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: history.width, height: history.height, depth: 1),
                to: history, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        command.present(drawable)
        let semaphore = slots
        command.addCompletedHandler { _ in semaphore.signal() }
        submitted = true
        lastDraw = now
        command.commit()
    }

    // Original effects plus user-supplied bundled logo artwork. No vendor shaders.
    static let shaderSource = [
        commonShaderSource,
        SIDBloomVisualization.shaderSource,
        SIDPulseVortexVisualization.shaderSource,
        SIDVectorFlowVisualization.shaderSource,
        SIDNeonTideVisualization.shaderSource,
        SIDPixelRiptideVisualization.shaderSource,
        SIDPulseRibbonsVisualization.shaderSource,
        SIDEchoTunnelVisualization.shaderSource,
        SIDNeonOrbitVisualization.shaderSource,
        SIDShardStormVisualization.shaderSource,
        SIDGrainNebulaVisualization.shaderSource,
        SIDDotMatrixVisualization.shaderSource,
        SIDSignalCollageVisualization.shaderSource,
        fragmentSource,
    ].joined(separator: "\n")

    private static let commonShaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms {
        float4 viewport, energy, style, rhythm, motion;
        float4 voices[9];
    };
    struct Raster { float4 position [[position]]; };
    vertex Raster sidVisualVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return { float4(p * 2.0 - 1.0, 0, 1) };
    }
    constant float tau = 6.2831853;
    float sidHash(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
    float3 palette(float h) {
        return 0.52 + 0.48 * cos(tau * (h + float3(0.0, 0.67, 0.33)));
    }
    float line(float distance, float width, float glow) {
        return exp(-distance * distance / max(width * width, 0.000001))
             + glow * 0.24 * exp(-abs(distance) / max(width * 5.0, 0.001));
    }
    float segment(float2 p, float2 a, float2 b) {
        float2 d = b-a;
        return length(p-a-d*clamp(dot(p-a,d)/max(dot(d,d),0.00001),0.0,1.0));
    }
    """#

    private static let fragmentSource = #"""
    fragment float4 sidVisualFragment(Raster in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                     texture2d<float> logo [[texture(1)]]) {
        float2 p=(in.position.xy/u.viewport.xy-0.5)*2.0;
        p.x*=u.viewport.x/u.viewport.y;
        float3 color;
        int mode=int(u.viewport.w);
        if(mode==0) color=flower(p,u);
        else if(mode==1) color=blackhole(p,u);
        else if(mode==2) color=vectorField(p,u);
        else if(mode==3) color=sea(p,u);
        else if(mode==4) color=pixelRiptide(p,u);
        else if(mode==5) color=pulseRibbons(p,u);
        else if(mode==6) color=echoTunnel(p,u);
        else if(mode==7) color=neonOrbit(p,u);
        else if(mode==8) color=shardStorm(p,u);
        else if(mode==9) color=grainNebula(p,u);
        else if(mode==10) color=dotMatrix(p,u);
        else if(mode==11) color=signalCollage(p,u,logo);
        else color=float3(0);
        float vignette=1.0-smoothstep(0.4,2.2,length(p))*0.55;
        color=1.0-exp(-max(color,0.0)*vignette);
        return float4(color,1);
    }
    """#
}
