import Foundation
import Metal
import MetalKit
import CoreGraphics
import simd

/// Renders indexed-color C64 frames using a Metal fragment shader that performs
/// palette lookup on the GPU. Scaling/filtering are applied via vertex transform
/// and sampler state — fully hardware accelerated.
final class MetalFrameRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState

    /// Ring of R8Uint textures holding palette indices. A frame is uploaded
    /// into the *next* texture, never the one bound to the in-flight command
    /// buffer — replace() is a CPU write and would tear the picture while a
    /// slow fragment shader (the CRT modes) is still reading it.
    private var indexTextures: [MTLTexture]
    private var currentTextureIndex = 0
    /// 16-entry RGBA palette texture.
    private var paletteTexture: MTLTexture

    private let textureLock = NSLock()
    private var pendingFrame: Data?
    /// Set by `requestFilteredScreenshot`, consumed on the next `draw(in:)`.
    /// Both are only ever touched on the main thread (MTKView's display
    /// link — and the occlusion-fallback timer — always call draw() there),
    /// so no locking is needed, unlike `pendingFrame` above.
    private var pendingScreenshotCompletion: ((CGImage?) -> Void)?
    /// Offscreen render target for screenshot capture, sized to match the
    /// live drawable. Reused across requests; recreated only if the view
    /// resizes.
    private var screenshotTexture: MTLTexture?

    // Render settings, updated from the UI.
    var scalingMode: ScalingMode = .aspectFit
    var filterMode: FilterMode = .sharp
    var reflectionEnabled: Bool = true
    /// 0 = S-Video, 1 = Composite, 2 = RF.
    var signalLevel: Float = 0
    /// Frame counter driving RF noise animation.
    private var frameIndex: UInt32 = 0
    /// Live picture controls, read every frame (bypasses SwiftUI updates
    /// so knob drags adjust the picture without re-rendering views).
    var picture: PictureControls?

    struct Uniforms {
        var scale: SIMD2<Float>
        var reflection: Float
        var signal: Float
        var time: Float
        var brightness: Float
        var contrast: Float
        var saturation: Float
        var tint: Float
        var padding: Float = 0
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    // Screen-position hash noise for dithering: breaks up 8-bit banding on
    // smooth gradients (vignette, reflection falloff) by adding ±0.5 LSB of
    // noise before the framebuffer quantizes. Visually it reads as grain far
    // below perception; the rings it removes are very visible.
    static float3 dither(float3 color, float2 pixelPos) {
        float n = fract(sin(dot(pixelPos, float2(12.9898, 78.233))) * 43758.5453);
        return color + (n - 0.5) / 255.0;
    }

    struct Uniforms {
        float2 scale;
        float reflection;
        float signal;
        float time;
        float brightness;
        float contrast;
        float saturation;
        float tint;
        float padding;
    };

    // Monitor picture controls, all neutral at 0.5. Saturation and tint
    // work on the chroma plane (YIQ), like the color/tint pots on a real
    // composite monitor.
    static float3 applyPicture(float3 c, constant Uniforms &u) {
        c = (c - 0.5) * mix(0.4, 1.6, u.contrast) + 0.5 + (u.brightness - 0.5) * 0.5;
        float3 yiq = float3(dot(c, float3(0.299,  0.587,  0.114)),
                            dot(c, float3(0.596, -0.274, -0.322)),
                            dot(c, float3(0.211, -0.523,  0.312)));
        float angle = (u.tint - 0.5) * 1.0;   // ~±28 degrees of hue
        float sn = sin(angle), cs = cos(angle);
        float2 iq = float2(yiq.y * cs - yiq.z * sn,
                           yiq.y * sn + yiq.z * cs) * (u.saturation * 2.0);
        float3 rgb = float3(yiq.x + 0.956 * iq.x + 0.621 * iq.y,
                            yiq.x - 0.272 * iq.x - 0.647 * iq.y,
                            yiq.x - 1.106 * iq.x + 1.703 * iq.y);
        return clamp(rgb, 0.0, 1.0);
    }

    vertex VertexOut vertexMain(uint vid [[vertex_id]],
                                constant Uniforms &uniforms [[buffer(0)]]) {
        // Fullscreen quad from two triangles (triangle strip).
        float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 texCoords[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        VertexOut out;
        out.position = float4(positions[vid] * uniforms.scale, 0, 1);
        out.texCoord = texCoords[vid];
        return out;
    }

    fragment float4 fragmentMain(VertexOut in [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]],
                                 texture2d<uint> indexTex [[texture(0)]],
                                 texture2d<float> paletteTex [[texture(1)]],
                                 sampler smp [[sampler(0)]]) {
        constexpr sampler pointSmp(coord::normalized, filter::nearest);
        uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
        uint2 coord = uint2(in.texCoord * float2(size));
        coord = min(coord, size - 1);
        uint index = indexTex.read(coord).r;
        float4 c = paletteTex.read(uint2(index, 0));
        return float4(applyPicture(c.rgb, uniforms), 1.0);
    }

    // Smooth variant: sample palette-expanded neighbors with manual bilinear blend.
    fragment float4 fragmentSmooth(VertexOut in [[stage_in]],
                                   constant Uniforms &uniforms [[buffer(0)]],
                                   texture2d<uint> indexTex [[texture(0)]],
                                   texture2d<float> paletteTex [[texture(1)]],
                                   sampler smp [[sampler(0)]]) {
        uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
        float2 pos = in.texCoord * float2(size) - 0.5;
        float2 f = fract(pos);
        int2 base = int2(floor(pos));
        float4 c[4];
        for (int i = 0; i < 4; i++) {
            int2 offset = int2(i & 1, i >> 1);
            uint2 coord = uint2(clamp(base + offset, int2(0), int2(size) - 1));
            uint index = indexTex.read(coord).r;
            c[i] = paletteTex.read(uint2(index, 0));
        }
        float4 top = mix(c[0], c[1], f.x);
        float4 bottom = mix(c[2], c[3], f.x);
        float4 blended = mix(top, bottom, f.y);
        return float4(applyPicture(blended.rgb, uniforms), 1.0);
    }

    // ---- CRT helpers ----

    static float4 sampleBilinear(float2 uv,
                                 texture2d<uint> indexTex,
                                 texture2d<float> paletteTex) {
        uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
        float2 pos = uv * float2(size) - 0.5;
        float2 f = fract(pos);
        int2 base = int2(floor(pos));
        float4 c[4];
        for (int i = 0; i < 4; i++) {
            int2 offset = int2(i & 1, i >> 1);
            uint2 coord = uint2(clamp(base + offset, int2(0), int2(size) - 1));
            uint index = indexTex.read(coord).r;
            c[i] = paletteTex.read(uint2(index, 0));
        }
        float4 top = mix(c[0], c[1], f.x);
        float4 bottom = mix(c[2], c[3], f.x);
        return mix(top, bottom, f.y);
    }

    static float3 toYIQ(float3 c) {
        return float3(dot(c, float3(0.299,  0.587,  0.114)),
                      dot(c, float3(0.596, -0.274, -0.322)),
                      dot(c, float3(0.211, -0.523,  0.312)));
    }

    static float3 fromYIQ(float3 yiq) {
        return float3(yiq.x + 0.956 * yiq.y + 0.621 * yiq.z,
                      yiq.x - 0.272 * yiq.y - 0.647 * yiq.z,
                      yiq.x - 1.106 * yiq.y + 1.703 * yiq.z);
    }

    static float hash21(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    // Composite/RF video: luma and chroma share one wire, so chroma
    // bandwidth collapses (color smears horizontally), luma softens, and
    // imperfect y/c separation leaves dot crawl on sharp chroma edges.
    // rf > 0.5 adds modulation artifacts: snow, horizontal jitter,
    // ghosting, and worse bandwidth all around.
    static float3 compositeSample(float2 uv, float2 pixelPos,
                                  texture2d<uint> indexTex,
                                  texture2d<float> paletteTex,
                                  float rf, float time) {
        uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
        float texelX = 1.0 / float(size.x);

        // RF: per-scanline horizontal jitter — tuner sync is never perfect.
        // Kept subtle: most lines sit still, an occasional line slips.
        if (rf > 0.5) {
            float line = floor(uv.y * float(size.y));
            float r = hash21(float2(line, floor(time * 8.0)));
            float jitter = (r - 0.5) * 0.14 + step(0.985, r) * 0.5;
            uv.x += jitter * texelX;
        }

        float lumaSoft = rf > 0.5 ? 0.75 : 0.45; // tap spacing; wider on RF
        float chromaStep = rf > 0.5 ? 1.5 : 0.9; // wider chroma smear on RF

        // Luma: 5-tap gaussian soften — on RF the taps sit far enough
        // apart that individual C64 pixels melt together.
        float3 cl = sampleBilinear(uv - float2(texelX * lumaSoft, 0), indexTex, paletteTex).rgb;
        float3 cr = sampleBilinear(uv + float2(texelX * lumaSoft, 0), indexTex, paletteTex).rgb;
        float y = 0.0;
        float ywsum = 0.0;
        for (int k = -2; k <= 2; k++) {
            float w = exp(-0.55 * float(k * k));
            float3 s = sampleBilinear(uv + float2(texelX * float(k) * lumaSoft, 0), indexTex, paletteTex).rgb;
            y += w * dot(s, float3(0.299, 0.587, 0.114));
            ywsum += w;
        }
        y /= ywsum;

        // Ghosting — a faint displaced copy from impedance mismatch.
        // Present on both cable inputs, stronger over the antenna.
        float ghostAmount = rf > 0.5 ? 0.06 : 0.025;
        float3 ghost = sampleBilinear(uv + float2(texelX * 5.0, 0), indexTex, paletteTex).rgb;
        y = mix(y, dot(ghost, float3(0.299, 0.587, 0.114)), ghostAmount);

        // Chroma: wide asymmetric horizontal average (~1.5 MHz bandwidth
        // feel) — color arrives late and smeared relative to luma.
        float2 iq = float2(0.0);
        float wsum = 0.0;
        for (int k = -1; k <= 4; k++) {
            float w = exp(-0.35 * float(k * k));
            float3 s = sampleBilinear(uv + float2(texelX * float(k) * chromaStep, 0), indexTex, paletteTex).rgb;
            float3 yiq = toYIQ(s);
            iq += w * yiq.yz;
            wsum += w;
        }
        iq /= wsum;

        // Dot crawl: on chroma transitions, the comb filter fails and a
        // checkerboard of residual subcarrier climbs the edge.
        float3 yiqL = toYIQ(cl), yiqR = toYIQ(cr);
        float chromaEdge = length(yiqR.yz - yiqL.yz);
        float crawl = chromaEdge * (rf > 0.5 ? 0.16 : 0.10) *
            ((int(pixelPos.x) + int(pixelPos.y)) % 2 == 0 ? 1.0 : -1.0);
        y += crawl;

        if (rf > 0.5) {
            // Snow: animated per-pixel luma noise.
            float snow = hash21(pixelPos + fract(time) * float2(731.0, 447.0));
            y += (snow - 0.5) * 0.10;
            // A single interference line drifting down the picture. Speed
            // is 8/60 rather than a rounder-looking 0.13: `time` itself
            // loops every 60s (frameIndex % 3600, see draw()), and 8/60
            // divides that evenly into exactly 8 whole sweeps with zero
            // remainder. 0.13 doesn't divide 60s evenly, so `time` was
            // resetting to 0 mid-sweep roughly once a minute, cutting the
            // line off before it reached the bottom instead of completing
            // its descent.
            float bandPos = fract(time * (8.0 / 60.0));
            float band = 1.0 - smoothstep(0.0, 0.012, abs(uv.y - bandPos));
            y += band * 0.05;
            // Chroma noise: color flecks, subtler than luma snow.
            float2 cnoise = float2(hash21(pixelPos + fract(time) * 311.0) - 0.5,
                                   hash21(pixelPos + fract(time) * 173.0) - 0.5);
            iq += cnoise * 0.03;
        }

        return clamp(fromYIQ(float3(y, iq)), 0.0, 1.0);
    }

    // Scanlines + phosphor triads + subtle bloom, applied to a flat image.
    // signal: 0 = S-Video (clean), 1 = composite, 2 = RF (composite + noise).
    static float3 crtShade(float2 uv, float2 pixelPos,
                           texture2d<uint> indexTex,
                           texture2d<float> paletteTex,
                           float signal, float time) {
        uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
        float3 color;
        if (signal > 0.5) {
            color = compositeSample(uv, pixelPos, indexTex, paletteTex,
                                    signal > 1.5 ? 1.0 : 0.0, time);
        } else {
            color = sampleBilinear(uv, indexTex, paletteTex).rgb;
        }

        // Soft horizontal bloom: neighbours bleed slightly.
        float2 texel = 1.0 / float2(size);
        float3 blur = sampleBilinear(uv + float2(texel.x, 0), indexTex, paletteTex).rgb
                    + sampleBilinear(uv - float2(texel.x, 0), indexTex, paletteTex).rgb;
        color = mix(color, blur * 0.5, 0.25);

        // Scanlines: darken between source rows, gently, luminance-dependent.
        float row = uv.y * float(size.y);
        float scan = sin(row * 3.14159265 * 2.0) * 0.5 + 0.5;   // 1 at row centers
        float lum = dot(color, float3(0.299, 0.587, 0.114));
        float scanStrength = mix(0.35, 0.15, lum);              // bright areas mask lines
        color *= mix(1.0 - scanStrength, 1.0, scan);

        // Phosphor triads: mild RGB stripe mask in device pixels.
        int px = int(pixelPos.x) % 3;
        float3 mask = px == 0 ? float3(1.05, 0.95, 0.95)
                    : px == 1 ? float3(0.95, 1.05, 0.95)
                              : float3(0.95, 0.95, 1.05);
        color *= mask;

        return color;
    }

    fragment float4 fragmentCRT(VertexOut in [[stage_in]],
                                constant Uniforms &uniforms [[buffer(0)]],
                                texture2d<uint> indexTex [[texture(0)]],
                                texture2d<float> paletteTex [[texture(1)]],
                                sampler smp [[sampler(0)]]) {
        float3 color = crtShade(in.texCoord, in.position.xy, indexTex, paletteTex, uniforms.signal, uniforms.time);
        return float4(dither(applyPicture(color, uniforms), in.position.xy), 1.0);
    }

    // Signed distance to the tube face: a rounded rect of half-extent 1.
    static float faceSDF(float2 p, float r) {
        float2 q = abs(p) - (1.0 - r);
        return length(max(q, 0.0)) - r;
    }

    // Tube variant: barrel distortion, rounded corners, vignette, and a
    // mirrored screen reflection on the sunken black mask around the face.
    fragment float4 fragmentCRTTube(VertexOut in [[stage_in]],
                                    constant Uniforms &uniforms [[buffer(0)]],
                                    texture2d<uint> indexTex [[texture(0)]],
                                    texture2d<float> paletteTex [[texture(1)]],
                                    sampler smp [[sampler(0)]]) {
        // Center coordinates in [-1, 1].
        float2 cc = in.texCoord * 2.0 - 1.0;

        // Barrel distortion: push samples outward toward the edges.
        float2 curved = cc * (1.0 + 0.028 * dot(cc, cc));

        const float radius = 0.08;
        float sd = faceSDF(curved, radius);

        if (sd >= 0.0) {
            // ---- The black mask: a recess between tube face and case. ----

            // Depth cues: the mask is sunken, so its outer rim (under the
            // case lip) sits in shadow, and light from above leaves the
            // top wall of the recess darker than the bottom. The lip
            // shadow uses a rounded-rect distance — a box metric
            // (max(|x|,|y|)) puts visible diagonal seams in the corners.
            float rimDist = -faceSDF(cc, 0.30);                 // 0 at the outer rim
            float lipShadow = smoothstep(-0.06, 0.30, rimDist); // dark under the lip
            float topShadow = mix(0.62, 1.0, smoothstep(-1.15, -0.25, cc.y));
            float3 base = float3(0.025) * lipShadow * topShadow;

            if (uniforms.reflection < 0.5) {
                return float4(dither(base, in.position.xy), 1.0);
            }

            // Sample the screen content directly adjacent to this mask
            // point: project onto the face edge along the SDF gradient and
            // step just inside the glass. The glow then follows the local
            // picture content along the whole edge (a band of color casts a
            // band of light of the same extent). True mirroring
            // (curved - 2·sd·n) pulls samples from ever-deeper inside the
            // picture as sd grows, which lands in wrong-neighborhood
            // content near corners and breaks that correspondence.
            float2 e = float2(0.002, 0.0);
            float2 n = normalize(float2(
                faceSDF(curved + e.xy, radius) - faceSDF(curved - e.xy, radius),
                faceSDF(curved + e.yx, radius) - faceSDF(curved - e.yx, radius)));
            float2 edgePoint = curved - (sd + 0.05) * n;
            float2 uvr = clamp(edgePoint * 0.5 + 0.5, 0.0, 1.0);

            // Matte surface: average a strip of picture just inside the
            // glass, mostly along the edge (tangential) so the glow tracks
            // the adjacent content, softened across it. Weighted toward the
            // center tap for a gaussian-ish, seam-free result.
            float2 t = float2(n.y, -n.x);
            float spread = 1.0 + sd * 6.0;
            float3 refl = float3(0.0);
            float wsum = 0.0;
            for (int i = -4; i <= 4; i++) {
                for (int j = -1; j <= 1; j++) {
                    float w = exp(-0.18 * float(i * i) - 0.5 * float(j * j));
                    float2 o = (t * (float(i) * 0.026) + n * (float(j) * 0.030)) * spread;
                    refl += w * sampleBilinear(clamp(uvr + o, 0.0, 1.0), indexTex, paletteTex).rgb;
                    wsum += w;
                }
            }
            refl /= wsum;

            refl = applyPicture(refl, uniforms);

            // Bloom: soft-knee boost so bright content flares while dark
            // content stays subtle.
            refl += refl * refl * 0.35;

            // Reflection dies off with distance from the glass: brightest
            // right at the picture edge (a gap there reads as a black ring),
            // decaying gently so the glow melts into the recess shadow.
            float fade = exp(-sd * 5.5);
            float3 color = base + refl * fade * 0.34 * mix(0.55, 1.0, lipShadow) * topShadow;
            return float4(dither(color, in.position.xy), 1.0);
        }

        // ---- Tube face ----
        float2 uv = curved * 0.5 + 0.5;
        // Soft antialiased edge just inside the border.
        float edge = 1.0 - smoothstep(-0.012, 0.0, sd);

        float3 color = applyPicture(crtShade(uv, in.position.xy, indexTex, paletteTex, uniforms.signal, uniforms.time), uniforms);

        // Vignette: gentle darkening toward edges, like a lit tube face.
        float vig = 1.0 - 0.22 * dot(cc, cc);
        color *= vig;

        return float4(dither(color * edge, in.position.xy), 1.0);
    }
    """

    private let sharpPipeline: MTLRenderPipelineState
    private let smoothPipeline: MTLRenderPipelineState
    private let crtPipeline: MTLRenderPipelineState
    private let crtTubePipeline: MTLRenderPipelineState

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Only redraw when a new frame arrives.
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 60

        // Compile shaders.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            NSLog("[render] shader compile FAILED: %@", String(describing: error))
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "vertexMain"),
              let fragmentSharp = library.makeFunction(name: "fragmentMain"),
              let fragmentSmooth = library.makeFunction(name: "fragmentSmooth"),
              let fragmentCRT = library.makeFunction(name: "fragmentCRT"),
              let fragmentCRTTube = library.makeFunction(name: "fragmentCRTTube") else {
            NSLog("[render] shader function lookup failed")
            return nil
        }

        func makePipeline(fragment: MTLFunction) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let sharp = makePipeline(fragment: fragmentSharp),
              let smooth = makePipeline(fragment: fragmentSmooth),
              let crt = makePipeline(fragment: fragmentCRT),
              let crtTube = makePipeline(fragment: fragmentCRTTube) else { return nil }
        self.sharpPipeline = sharp
        self.smoothPipeline = smooth
        self.crtPipeline = crt
        self.crtTubePipeline = crtTube
        self.pipelineState = sharp

        // Samplers.
        func makeSampler(filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let desc = MTLSamplerDescriptor()
            desc.minFilter = filter
            desc.magFilter = filter
            desc.sAddressMode = .clampToEdge
            desc.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: desc)
        }
        guard let nearest = makeSampler(filter: .nearest),
              let linear = makeSampler(filter: .linear) else { return nil }
        self.nearestSampler = nearest
        self.linearSampler = linear

        // Index textures: one byte per pixel, triple-buffered so uploads
        // never touch a texture the GPU is reading.
        let indexDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint,
            width: VideoReceiver.width,
            height: VideoReceiver.height,
            mipmapped: false)
        indexDesc.usage = [.shaderRead]
        var textures: [MTLTexture] = []
        for _ in 0..<3 {
            guard let tex = device.makeTexture(descriptor: indexDesc) else { return nil }
            textures.append(tex)
        }
        self.indexTextures = textures

        // Palette texture: 16x1 RGBA.
        let paletteDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 16,
            height: 1,
            mipmapped: false)
        paletteDesc.usage = [.shaderRead]
        guard let paletteTex = device.makeTexture(descriptor: paletteDesc) else { return nil }
        self.paletteTexture = paletteTex

        super.init()
        setPalette(C64Palette.pepto)
        mtkView.delegate = self
    }

    func setPalette(_ palette: [SIMD4<UInt8>]) {
        precondition(palette.count == 16)
        var bytes = [UInt8]()
        bytes.reserveCapacity(64)
        for color in palette {
            bytes.append(contentsOf: [color.x, color.y, color.z, color.w])
        }
        paletteTexture.replace(
            region: MTLRegionMake2D(0, 0, 16, 1),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: 64)
    }

    /// Requests a screenshot of exactly what's on screen — the active
    /// filter (CRT tube curvature, scanlines, phosphor mask, composite/RF
    /// artifacts), palette, and picture controls all included. Captured on
    /// the *next* draw() by re-running the same pipeline and uniforms into
    /// an offscreen texture (the live drawable can't be read back directly:
    /// MTKView's default `framebufferOnly = true` disallows it), so the
    /// completion arrives one frame later, off the main thread — hop back
    /// before touching anything else.
    func requestFilteredScreenshot(completion: @escaping (CGImage?) -> Void) {
        pendingScreenshotCompletion = completion
    }

    /// Encodes an extra render pass — same pipeline, uniforms, and source
    /// textures as the frame just drawn — into an offscreen texture sized
    /// to match the live drawable. Matching that size matters: the phosphor
    /// mask and scanline shading key off destination pixel coordinates
    /// (`in.position.xy`), so rendering at a different resolution would
    /// produce a different-looking result than what's actually on screen.
    private func encodeScreenshotPass(commandBuffer: MTLCommandBuffer,
                                      pipeline: MTLRenderPipelineState,
                                      uniforms: Uniforms,
                                      indexTexture: MTLTexture,
                                      drawableSize: CGSize,
                                      completion: @escaping (CGImage?) -> Void) {
        let width = max(1, Int(drawableSize.width))
        let height = max(1, Int(drawableSize.height))
        if screenshotTexture == nil || screenshotTexture!.width != width || screenshotTexture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .shared
            screenshotTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let target = screenshotTexture else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = target
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(indexTexture, index: 0)
        encoder.setFragmentTexture(paletteTexture, index: 1)
        encoder.setFragmentSamplerState(filterMode == .sharp ? nearestSampler : linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            let image = self?.readScreenshotTexture(width: width, height: height)
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Reads the offscreen texture back to CPU. Called from the command
    /// buffer's completion handler (an arbitrary Metal-internal thread) —
    /// safe because that handler only fires once the GPU has finished
    /// writing, and nothing else touches this texture concurrently for the
    /// brief window between encoding and readback.
    private func readScreenshotTexture(width: Int, height: Int) -> CGImage? {
        guard let texture = screenshotTexture else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        // bgra8Unorm stores B,G,R,A per pixel. premultipliedFirst +
        // byteOrder32Little is the standard CGImage recipe for describing a
        // BGRA buffer without a manual channel-swap pass (alpha is always
        // 1.0 here, so "premultiplied" vs. "none" makes no visible difference).
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height,
                        bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: bytesPerRow,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: bitmapInfo,
                        provider: provider, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)
    }

    private static let debug = ProcessInfo.processInfo.environment["UV_DEBUG"] == "1"
    private var dbgSubmitted = 0
    private var dbgDrawn = 0

    /// Called from the receiver thread with a new frame of palette indices.
    func submitFrame(_ frame: Data) {
        textureLock.lock()
        pendingFrame = frame
        if Self.debug {
            dbgSubmitted += 1
            if dbgSubmitted % 100 == 1 {
                NSLog("[render] submitted=%d drawn=%d", dbgSubmitted, dbgDrawn)
            }
        }
        textureLock.unlock()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Upload the most recent frame, if any.
        textureLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        textureLock.unlock()

        if let frame {
            if Self.debug {
                dbgDrawn += 1
                if dbgDrawn % 100 == 1 {
                    NSLog("[render] draw: uploading frame %d, drawableSize=%.0fx%.0f", dbgDrawn, view.drawableSize.width, view.drawableSize.height)
                }
            }
            // Rotate to the next texture in the ring before uploading: the
            // previous one may still be read by an in-flight command buffer.
            currentTextureIndex = (currentTextureIndex + 1) % indexTextures.count
            frame.withUnsafeBytes { raw in
                indexTextures[currentTextureIndex].replace(
                    region: MTLRegionMake2D(0, 0, VideoReceiver.width, VideoReceiver.height),
                    mipmapLevel: 0,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: VideoReceiver.width)
            }
        }

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let pipeline: MTLRenderPipelineState
        switch filterMode {
        case .sharp: pipeline = sharpPipeline
        case .smooth: pipeline = smoothPipeline
        case .crt: pipeline = crtPipeline
        case .crtTube: pipeline = crtTubePipeline
        }

        frameIndex &+= 1
        var uniforms = Uniforms(scale: computeScale(drawableSize: view.drawableSize),
                                reflection: reflectionEnabled ? 1 : 0,
                                signal: signalLevel,
                                time: Float(frameIndex % 3600) / 60.0,
                                brightness: picture?.brightness ?? 0.5,
                                contrast: picture?.contrast ?? 0.5,
                                saturation: picture?.saturation ?? 0.5,
                                tint: picture?.tint ?? 0.5)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(indexTextures[currentTextureIndex], index: 0)
        encoder.setFragmentTexture(paletteTexture, index: 1)
        encoder.setFragmentSamplerState(filterMode == .sharp ? nearestSampler : linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        if let shotCompletion = pendingScreenshotCompletion {
            pendingScreenshotCompletion = nil
            encodeScreenshotPass(commandBuffer: commandBuffer, pipeline: pipeline, uniforms: uniforms,
                                 indexTexture: indexTextures[currentTextureIndex],
                                 drawableSize: view.drawableSize, completion: shotCompletion)
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func computeScale(drawableSize: CGSize) -> SIMD2<Float> {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return .one }
        // A C64 on a real TV displays at 4:3 — the 384x272 frame's pixels
        // are not square, so scaling targets the display aspect, not the
        // pixel dimensions.
        let displayAspect: Float = 4.0 / 3.0
        let frameH = Float(VideoReceiver.height)
        let viewW = Float(drawableSize.width)
        let viewH = Float(drawableSize.height)

        switch scalingMode {
        case .fill:
            return SIMD2<Float>(1, 1)
        case .aspectFit:
            let outH = min(viewH, viewW / displayAspect)
            return SIMD2<Float>(outH * displayAspect / viewW, outH / viewH)
        case .integer:
            // Whole multiples of the source height, width follows 4:3.
            let maxScale = min(viewH / frameH, viewW / (frameH * displayAspect))
            let scale = max(1, floor(maxScale))
            let outH = frameH * scale
            return SIMD2<Float>(outH * displayAspect / viewW, outH / viewH)
        }
    }
}

/// Standard C64 palettes (RGBA).
enum C64Palette {
    static let pepto: [SIMD4<UInt8>] = [
        .init(0x00, 0x00, 0x00, 0xFF), .init(0xFF, 0xFF, 0xFF, 0xFF),
        .init(0x68, 0x37, 0x2B, 0xFF), .init(0x70, 0xA4, 0xB2, 0xFF),
        .init(0x6F, 0x3D, 0x86, 0xFF), .init(0x58, 0x8D, 0x43, 0xFF),
        .init(0x35, 0x28, 0x79, 0xFF), .init(0xB8, 0xC7, 0x6F, 0xFF),
        .init(0x6F, 0x4F, 0x25, 0xFF), .init(0x43, 0x39, 0x00, 0xFF),
        .init(0x9A, 0x67, 0x59, 0xFF), .init(0x44, 0x44, 0x44, 0xFF),
        .init(0x6C, 0x6C, 0x6C, 0xFF), .init(0x9A, 0xD2, 0x84, 0xFF),
        .init(0x6C, 0x5E, 0xB5, 0xFF), .init(0x95, 0x95, 0x95, 0xFF),
    ]

    static let colodore: [SIMD4<UInt8>] = [
        .init(0x00, 0x00, 0x00, 0xFF), .init(0xFF, 0xFF, 0xFF, 0xFF),
        .init(0x81, 0x33, 0x38, 0xFF), .init(0x75, 0xCE, 0xC8, 0xFF),
        .init(0x8E, 0x3C, 0x97, 0xFF), .init(0x56, 0xAC, 0x4D, 0xFF),
        .init(0x2E, 0x2C, 0x9B, 0xFF), .init(0xED, 0xF1, 0x71, 0xFF),
        .init(0x8E, 0x50, 0x29, 0xFF), .init(0x55, 0x38, 0x00, 0xFF),
        .init(0xC4, 0x6C, 0x71, 0xFF), .init(0x4A, 0x4A, 0x4A, 0xFF),
        .init(0x7B, 0x7B, 0x7B, 0xFF), .init(0xA9, 0xFF, 0x9F, 0xFF),
        .init(0x70, 0x6D, 0xEB, 0xFF), .init(0xB2, 0xB2, 0xB2, 0xFF),
    ]

    static let vice: [SIMD4<UInt8>] = [
        .init(0x00, 0x00, 0x00, 0xFF), .init(0xFF, 0xFF, 0xFF, 0xFF),
        .init(0xB5, 0x68, 0x5C, 0xFF), .init(0x8D, 0xD8, 0xE0, 0xFF),
        .init(0xBA, 0x69, 0xC0, 0xFF), .init(0x7F, 0xCE, 0x67, 0xFF),
        .init(0x63, 0x5F, 0xC7, 0xFF), .init(0xF2, 0xF0, 0x8A, 0xFF),
        .init(0xBD, 0x7E, 0x4A, 0xFF), .init(0x8A, 0x66, 0x00, 0xFF),
        .init(0xE2, 0x9A, 0x8E, 0xFF), .init(0x6D, 0x6D, 0x6D, 0xFF),
        .init(0x95, 0x95, 0x95, 0xFF), .init(0xC1, 0xFF, 0xA9, 0xFF),
        .init(0x9E, 0x9A, 0xFF, 0xFF), .init(0xBC, 0xBC, 0xBC, 0xFF),
    ]

    static func palette(for choice: PaletteChoice) -> [SIMD4<UInt8>] {
        switch choice {
        case .pepto: return pepto
        case .colodore: return colodore
        case .vice: return vice
        }
    }
}

extension SIMD4 where Scalar == UInt8 {
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
        self.init(x: r, y: g, z: b, w: a)
    }
}

extension SIMD2 where Scalar == Float {
    static var one: SIMD2<Float> { SIMD2<Float>(1, 1) }
}
