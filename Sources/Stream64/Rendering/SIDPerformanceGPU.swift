import AppKit
import MetalKit

/// Shared direct-GPU drawing for measured spectra/waveforms and artwork. Only
/// numeric analysis data is uploaded each frame; artwork is decoded once.
final class SIDPerformanceGPU {
    enum Scene: Int { case spectrum, barField, waveform, showcase, waterfall, spectrogram }
    static let sampleCount = 256
    static let historyRows = 160
    static let bins = 48
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let artwork: MTLTexture
    private let labels: MTLTexture
    private static let cacheLock = NSLock()
    private static var cache: [UInt64: (MTLRenderPipelineState, MTLTexture, MTLTexture)] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.cache[device.registryID] {
            pipeline = cached.0; artwork = cached.1; labels = cached.2
            return
        }
        let source = Self.common + SIDSpectrumGPU.shader + SIDBarFieldGPU.shader
            + SIDWaveformGPU.shader + SIDShowcaseGPU.shader + Self.fragment
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "performanceVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "performanceFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        artwork = try Self.makeArtwork(device)
        labels = try Self.makeLabels(device)
        Self.cache[device.registryID] = (pipeline, artwork, labels)
    }

    func encode(command: MTLCommandBuffer, target: MTLTexture, scene: Scene,
                input: SIDGenerativeUniforms, channels: [SIDVoiceChannel], history: [[Float]], time: Float) -> Bool {
        var data = [Float](repeating: 0, count: 9 * Self.sampleCount + Self.historyRows * Self.bins)
        for channel in channels where (0..<9).contains(channel.id) {
            let samples = channel.orderedSamples
            guard !samples.isEmpty else { continue }
            for x in 0..<Self.sampleCount {
                data[channel.id * Self.sampleCount + x] = samples[x * (samples.count - 1) / (Self.sampleCount - 1)]
            }
        }
        let rows = Array(history.suffix(Self.historyRows))
        for (row, bars) in rows.enumerated() where !bars.isEmpty {
            for bin in 0..<Self.bins {
                data[9 * Self.sampleCount + row * Self.bins + bin] = bars[min(bars.count - 1, bin * bars.count / Self.bins)]
            }
        }
        var uniforms = input
        uniforms.viewport = SIMD4(Float(target.width), Float(target.height), max(0, time), Float(scene.rawValue))
        uniforms.motion.w = Float(rows.count)
        guard let buffer = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<Float>.stride),
              let encoder = command.makeRenderCommandEncoder(descriptor: Self.pass(target)) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIDGenerativeUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 1)
        encoder.setFragmentTexture(artwork, index: 0)
        encoder.setFragmentTexture(labels, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private static func pass(_ target: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private static func makeArtwork(_ device: MTLDevice) throws -> MTLTexture {
        let width = 512, height = 384
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = width; descriptor.height = height
        descriptor.arrayLength = 6
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw CocoaError(.coderInvalidValue) }
        for (index, image) in SIDShowcaseLayout.images.enumerated() {
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = context.data else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let scale = min(CGFloat(width) / CGFloat(cg.width), CGFloat(height) / CGFloat(cg.height))
            let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
            // CGImage bitmap rows already match Metal texture sampling; do not flip artwork.
            context.draw(cg, in: CGRect(x: (CGFloat(width)-w)/2, y: (CGFloat(height)-h)/2, width: w, height: h))
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: index,
                withBytes: bytes, bytesPerRow: width * 4, bytesPerImage: width * height * 4)
        }
        return texture
    }

    /// Static text atlas: upload once, select the rotating voice caption on the GPU.
    private static func makeLabels(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 512; descriptor.height = 32; descriptor.arrayLength = 54
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw CocoaError(.coderInvalidValue) }
        for index in 0..<54 {
            let caption = "\(SIDShowcaseLayout.names[index / 9])  ·  SID \(index % 9 / 3 + 1) V\(index % 3 + 1)"
            guard let context = CGContext(data: nil, width: 512, height: 32, bitsPerComponent: 8,
                bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = context.data else {
                throw CocoaError(.coderInvalidValue)
            }
            context.translateBy(x: 0, y: 32); context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let text = NSAttributedString(string: caption, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white])
            text.draw(at: NSPoint(x: (512-text.size().width)/2, y: 0))
            NSGraphicsContext.restoreGraphicsState()
            texture.replace(region: MTLRegionMake2D(0, 0, 512, 32), mipmapLevel: 0, slice: index,
                withBytes: bytes, bytesPerRow: 2048, bytesPerImage: 65536)
        }
        return texture
    }

    private static let common = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct PerformanceUniforms { float4 viewport,energy,style,rhythm,motion; float4 voices[9]; };
    vertex float4 performanceVertex(uint id [[vertex_id]]) {
        float2 p=float2((id<<1)&2,id&2); return float4(p*2-1,0,1);
    }
    float3 performanceColor(float h) { return .52+.48*cos(6.2831853*(h+float3(0,.67,.33))); }
    float spectrumValue(const device float* data,int row,int bin) {
        return clamp(data[2304+clamp(row,0,159)*48+clamp(bin,0,47)],0.0,1.0);
    }
    """#
    private static let fragment = #"""
    fragment float4 performanceFragment(float4 p [[position]],
        constant PerformanceUniforms& u [[buffer(0)]], const device float* data [[buffer(1)]],
        texture2d_array<float> art [[texture(0)]], texture2d_array<float> labels [[texture(1)]]) {
        float2 uv=p.xy/u.viewport.xy; float3 c=0;
        int mode=int(u.viewport.w);
        if(mode==0) c=performanceSpectrum(uv,u,data);
        else if(mode==1 || mode==4) c=performanceBarField(uv,u,data,mode==4);
        else if(mode==2) c=performanceWaveform(uv,u,data);
        else if(mode==3) c=performanceShowcase(p.xy,u,art,labels);
        else if(mode==5) {
            int row=int(uv.x*160)-(160-int(u.motion.w));
            float v=row<0 ? 0.0 : spectrumValue(data,row,int((1-uv.y)*48));
            c=float3(clamp(v*3,0.0,1.0),clamp(v*3-1,0.0,1.0),clamp(v*3-2,0.0,1.0));
        }
        return float4(clamp(c,0.0,1.0),1);
    }
    """#
}
