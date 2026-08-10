import Foundation
import Metal
import MetalKit
import CoreGraphics
import simd

/// Renders indexed-color C64 frames using a Metal fragment shader that performs
/// palette lookup on the GPU. Scaling/filtering are applied via vertex transform
/// and sampler state — fully hardware accelerated.
final class MetalFrameRenderer: NSObject, MTKViewDelegate {
    private weak var renderView: MTKView?
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
    private static let historyFrameCount = 12
    /// Indexed source-frame history for amber phosphor persistence
    /// (~240 ms at the PAL stream's 50 fps).
    private let historyTexture: MTLTexture
    private var historyHead = 0
    private var historyValidCount = 0
    private var historyLastUploadUptime: UInt64 = 0
    /// 16-entry RGBA palette texture.
    private var paletteTexture: MTLTexture
    /// Photographic RGBA dirt/lint mask generated for the neglected-glass
    /// mode. Procedural detail is layered on top so repeated installations
    /// share material realism without looking perfectly uniform.
    private let dirtyGlassTexture: MTLTexture

    private let textureLock = NSLock()
    /// Limits CPU uploads to resources whose previous GPU command buffer has
    /// completed. Fixed ring rotation alone is not enough when a CRT shader
    /// stalls for more than three frames.
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private var palettePendingBytes: [UInt8]?
    private var pendingFrame: Data?
    private var resetHistoryOnNextFrame = false
    private var lastFrameSubmission: DispatchTime?
    /// Ensures a semaphore miss still gets one follow-up draw once the GPU
    /// catches up (demand-driven path would otherwise stall until the next
    /// UDP frame / RF timer tick).
    private var deferredRedrawPending = false
    /// Recent in-flight semaphore misses; ≥2 means the CRT GPU path is behind.
    private var recentSemaphoreMisses = 0
    /// Consecutive slow presents while UDP frames are still arriving — detects
    /// main-thread starvation (SID / 3D map) that never trips the semaphore.
    private var slowPresentStreak = 0
    private var lastSuccessfulPresentTime: DispatchTime?
    private(set) var isGPUBehind = false
    private var presentCount = 0
    private var lastPresentStatsTime = DispatchTime.now()
    private var lastReportedPresentFPS: Double = 0
    /// Main-thread callback with present FPS and display-behind state (~1 Hz,
    /// plus immediate flips of the behind flag).
    var onLoadStats: ((_ presentFPS: Double, _ gpuBehind: Bool) -> Void)?
    /// Set by `requestFilteredScreenshot`, consumed on the next `draw(in:)`.
    /// Both are only ever touched on the main thread (MTKView's display
    /// link — and the occlusion-fallback timer — always call draw() there),
    /// so no locking is needed, unlike `pendingFrame` above.
    private var pendingScreenshotCompletion: ((CGImage?) -> Void)?
    // Render settings, updated from the UI.
    var scalingMode: ScalingMode = .aspectFit
    var filterMode: FilterMode = .sharp
    var reflectionEnabled: Bool = true
    /// 0 = S-Video, 1 = Composite, 2 = RF.
    var signalLevel: Float = 0
    var crtScreenColor: CRTScreenColor = .color
    var crtDirtyGlass: Bool = false
    var monitorDotPitchMillimeters: Float = BezelChoice.c1702.dotPitchMillimeters
    /// 0 = standalone/fullscreen dark bezel, 1 = 1702, 2 = 1084S.
    var bezelSurfaceMode: Float = 0
    private var powerOffEffectStartedAt: UInt64?
    private var animationTimer: Timer?
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
        var phosphorColor: Float
        var dirtyGlass: Float
        var maskPitch: Float
        var historyHead: Float
        var historyValidCount: Float
        var historyPhase: Float
        var powerOff: Float
        var bezelSurfaceMode: Float
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
        float phosphorColor;
        float dirtyGlass;
        float maskPitch;
        float historyHead;
        float historyValidCount;
        float historyPhase;
        float powerOff;
        float bezelSurfaceMode;
        float padding;
    };

    // Monitor picture controls, all neutral at 0.5. Saturation and tint
    // work on the chroma plane (YIQ), like the color/tint pots on a real
    // composite monitor.
    static float brightnessOffset(constant Uniforms &u) {
        // Preserve a useful darkening range, but provide substantially more
        // headroom above neutral for a deliberately overdriven CRT picture.
        return u.brightness < 0.5
             ? (u.brightness - 0.5) * 0.70
             : (u.brightness - 0.5) * 1.30;
    }

    static float saturationScale(constant Uniforms &u) {
        // 0...0.5 remains a conventional 0...1 saturation control.
        // Above neutral, ramp much harder to 4x chroma at the end stop.
        return u.saturation <= 0.5
             ? u.saturation * 2.0
             : 1.0 + (u.saturation - 0.5) * 6.0;
    }

    static float3 applyPicture(float3 c, constant Uniforms &u) {
        c = (c - 0.5) * mix(0.4, 1.6, u.contrast)
          + 0.5 + brightnessOffset(u);
        float3 yiq = float3(dot(c, float3(0.299,  0.587,  0.114)),
                            dot(c, float3(0.596, -0.274, -0.322)),
                            dot(c, float3(0.211, -0.523,  0.312)));
        float angle = (u.tint - 0.5) * 1.0;   // ~±28 degrees of hue
        float sn = sin(angle), cs = cos(angle);
        float2 iq = float2(yiq.y * cs - yiq.z * sn,
                           yiq.y * sn + yiq.z * cs) * saturationScale(u);
        float3 rgb = float3(yiq.x + 0.956 * iq.x + 0.621 * iq.y,
                            yiq.x - 0.272 * iq.x - 0.647 * iq.y,
                            yiq.x - 1.106 * iq.x + 1.703 * iq.y);
        return clamp(rgb, 0.0, 1.0);
    }

    // Physical CRT phosphor color applied after picture controls. Color mode
    // leaves RGB intact; amber/green/monochrome convert the decoded picture
    // to luminance, then excite a single-color or white phosphor.
    static float3 applyPhosphorColor(float3 c, constant Uniforms &u) {
        if (u.phosphorColor < 0.5) {
            return c;
        }
        // applyPicture intentionally lifts/lowers the entire signal with the
        // monitor controls. A monochrome phosphor should not turn that lifted
        // black level into a glowing amber/green background, so subtract the
        // exact output level that a true RGB black receives from those same
        // controls before tinting. Signal noise above black remains visible.
        float contrastScale = mix(0.4, 1.6, u.contrast);
        float blackLevel = clamp(0.5 - 0.5 * contrastScale
                               + brightnessOffset(u), 0.0, 0.98);
        float luminance = dot(c, float3(0.299, 0.587, 0.114));
        luminance = max(0.0, (luminance - blackLevel)
                             / max(1.0 - blackLevel, 0.001));
        if (u.phosphorColor > 0.5 && u.phosphorColor < 2.5) {
            // A real monochrome tube's "black" is not absolute once its
            // brightness is driven: the raster becomes a faint phosphor-
            // colored haze. Low contrast lifts it a little more; high
            // contrast suppresses the floor while bright phosphor remains
            // strongly driven. Neutral controls still produce true black.
            float brightnessDrive = clamp((u.brightness - 0.5) * 2.0,
                                          0.0, 1.0);
            float lowContrastLift = clamp((0.5 - u.contrast) * 2.0,
                                          0.0, 1.0);
            float highContrastCrush = clamp((u.contrast - 0.5) * 2.0,
                                            0.0, 1.0);
            float phosphorFloor = (brightnessDrive * 0.18
                                 + lowContrastLift * 0.07)
                                * (1.0 - highContrastCrush * 0.65);
            luminance += phosphorFloor * (1.0 - luminance);
        }
        if (u.phosphorColor < 1.5) {
            float glow = min(1.0, luminance * 1.08
                                  + luminance * luminance * 0.20);
            // Period amber phosphor is not one fixed RGB color: low emission
            // reads brown/orange, while strong emission shifts toward a
            // golden yellow. Interpolate by beam intensity to reproduce that
            // characteristic palette from real monochrome monitors.
            float amberMix = smoothstep(0.08, 0.82, glow);
            float3 darkAmber = float3(0.82, 0.34, 0.01);
            float3 brightAmber = float3(1.0, 0.76, 0.06);
            return glow * mix(darkAmber, brightAmber, amberMix);
        }
        if (u.phosphorColor < 2.5) {
            float glow = min(1.0, luminance * 1.08
                                  + luminance * luminance * 0.20);
            return glow * float3(0.20, 1.0, 0.32);
        }
        return float3(luminance);
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

    static float3 sampleHistoryColor(
        float2 uv, uint slice,
        texture2d_array<uint> historyTex,
        texture2d<float> paletteTex) {
        uint2 size = uint2(historyTex.get_width(), historyTex.get_height());
        uint2 coord = min(uint2(clamp(uv, 0.0, 1.0) * float2(size)),
                          size - 1);
        uint index = historyTex.read(coord, slice).r;
        return paletteTex.read(uint2(index, 0)).rgb;
    }

    static float3 sampleIndexedColorNearest(
        float2 uv, texture2d<uint> indexTex,
        texture2d<float> paletteTex) {
        uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
        uint2 coord = min(uint2(clamp(uv, 0.0, 1.0) * float2(size)),
                          size - 1);
        uint index = indexTex.read(coord).r;
        return paletteTex.read(uint2(index, 0)).rgb;
    }

    static float3 roughReflectionSample(
        float2 uv, float2 tangentOffset,
        texture2d<uint> indexTex,
        texture2d<float> paletteTex) {
        float3 sample = sampleBilinear(uv, indexTex, paletteTex).rgb * 0.76;
        sample += sampleBilinear(
            clamp(uv - tangentOffset, 0.0, 1.0),
            indexTex, paletteTex).rgb * 0.12;
        sample += sampleBilinear(
            clamp(uv + tangentOffset, 0.0, 1.0),
            indexTex, paletteTex).rgb * 0.12;
        return sample;
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

    static float dirtNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    static float2 rotateDirt(float2 p, float angle) {
        float sn = sin(angle), cs = cos(angle);
        return float2(p.x * cs - p.y * sn, p.x * sn + p.y * cs);
    }

    static float dirtEllipse(float2 uv, float2 center,
                             float2 radius, float angle) {
        float2 p = rotateDirt(uv - center, angle) / radius;
        return 1.0 - smoothstep(0.65, 1.25, length(p));
    }

    static float moistureRing(float2 uv, float2 center, float radius) {
        float d = length(uv - center);
        float ringWidth = max(0.0012, radius * 0.16);
        float ring = 1.0 - smoothstep(ringWidth * 0.30, ringWidth,
                                     abs(d - radius));
        float driedCenter = (1.0 - smoothstep(0.0, radius, d)) * 0.22;
        return max(ring, driedCenter);
    }

    static float2 dropletRefraction(float2 uv, float2 center,
                                    float radius, float strength) {
        float2 delta = uv - center;
        float distance = length(delta);
        float inside = 1.0 - smoothstep(radius * 0.30, radius, distance);
        float rim = 1.0 - smoothstep(0.0, radius,
                                     abs(distance - radius * 0.72));
        float2 direction = delta / max(distance, 0.0001);
        return direction * (inside * 0.00065 + rim * 0.00040) * strength;
    }

    // Years of grime refract the source picture locally before phosphor and
    // glass overlays are evaluated. The pattern is static in screen space so
    // it stays attached to the physical tube rather than the video content.
    static float2 dirtyGlassUV(float2 uv, constant Uniforms &u) {
        if (u.dirtyGlass < 0.5) {
            return uv;
        }
        float2 offset = float2(0.0);
        offset += dropletRefraction(uv, float2(0.73, 0.28), 0.009, 1.0);
        offset += dropletRefraction(uv, float2(0.31, 0.72), 0.006, 0.8);
        offset += dropletRefraction(uv, float2(0.56, 0.57), 0.0035, 0.55);
        return clamp(uv + offset, 0.0, 1.0);
    }

    static float3 applyDirtyGlass(float3 color, float2 uv,
                                  float2 pixelPos, constant Uniforms &u,
                                  texture2d<float> dirtTexture) {
        if (u.dirtyGlass < 0.5) {
            return color;
        }

        // Uneven nicotine/dust film at two scales.
        float broadFilm = dirtNoise(uv * 3.2 + float2(1.7, 4.1));
        float fineFilm = dirtNoise(uv * 13.0 + float2(8.3, 2.2));
        float film = broadFilm * 0.68 + fineFilm * 0.32;

        // Finger wipes, palm smears and a long dried cleaning streak.
        float smudge = 0.0;
        smudge += dirtEllipse(uv, float2(0.21, 0.25),
                              float2(0.18, 0.040), -0.22) * 0.72;
        smudge += dirtEllipse(uv, float2(0.79, 0.68),
                              float2(0.16, 0.034), 0.36) * 0.58;
        smudge += dirtEllipse(uv, float2(0.43, 0.82),
                              float2(0.22, 0.022), -0.08) * 0.40;
        smudge = clamp(smudge, 0.0, 1.0);

        // Dried moisture spots: pale mineral rings with cloudy centers.
        float moisture = 0.0;
        moisture += moistureRing(uv, float2(0.73, 0.28), 0.015);
        moisture += moistureRing(uv, float2(0.31, 0.72), 0.010) * 0.78;
        moisture += moistureRing(uv, float2(0.56, 0.57), 0.006) * 0.62;
        moisture = clamp(moisture, 0.0, 1.0);

        // Photographic material mask generated specifically for neglected CRT
        // glass. Crop its 3:2 source to the centered 4:3 screen area. Strong
        // opacity is limited to a small area in the extreme corners; the
        // source mask is heavily attenuated everywhere else.
        constexpr sampler dirtSampler(coord::normalized, filter::linear,
                                       address::clamp_to_edge);
        // Shift the photographed buildup down so it sits directly in the
        // glass/case seam rather than floating above the bottom edge.
        float2 dirtUV = float2(
            uv.x * 0.8888889 + 0.0555556,
            clamp(uv.y - 0.035, 0.0, 1.0));
        float4 materialDirt = dirtTexture.sample(dirtSampler, dirtUV);
        float leftWeight = 1.0 - smoothstep(
            0.35, 1.0,
            length((uv - float2(0.0, 1.0)) / float2(0.22, 0.11)));
        float rightWeight = 1.0 - smoothstep(
            0.35, 1.0,
            length((uv - float2(1.0, 1.0)) / float2(0.22, 0.11)));
        float cornerWeight = max(leftWeight, rightWeight);
        float materialOpacity = materialDirt.a
                              * mix(0.02, 0.32, cornerWeight);

        // Thousands of fixed dust motes, each placed within a 6-pixel cell.
        float2 cell = floor(pixelPos / 6.0);
        float2 local = fract(pixelPos / 6.0);
        float random = hash21(cell + float2(19.1, 7.7));
        float2 motePosition = float2(
            hash21(cell + float2(2.3, 5.9)),
            hash21(cell + float2(11.7, 3.1)));
        float mote = (1.0 - smoothstep(0.025, 0.13,
                                      length(local - motePosition)))
                   * step(0.70, random);

        // A separate sparse population of 1–2 pixel embedded grime flecks.
        // These are darker and slightly brown/olive rather than neutral dust,
        // with enough spacing that each reads as an isolated particle.
        float2 fleckCell = floor(pixelPos / 10.0);
        float2 fleckLocal = fract(pixelPos / 10.0);
        float fleckRandom = hash21(fleckCell + float2(31.7, 13.9));
        float2 fleckPosition = float2(
            hash21(fleckCell + float2(6.1, 17.3)),
            hash21(fleckCell + float2(23.9, 4.7)));
        float darkFleck = (1.0 - smoothstep(0.025, 0.11,
                                           length(fleckLocal - fleckPosition)))
                        * step(0.94, fleckRandom);
        float fleckHue = hash21(fleckCell + float2(41.3, 29.1));
        float3 brownFleck = float3(0.18, 0.10, 0.045);
        float3 oliveFleck = float3(0.10, 0.17, 0.055);
        float3 fleckTransmission = mix(brownFleck, oliveFleck, fleckHue);

        float grime = 0.055 + film * 0.11 + smudge * 0.20
                    + moisture * 0.10;
        float luminance = dot(color, float3(0.299, 0.587, 0.114));
        // Dirty glass lowers contrast, warms transmitted light, and reflects
        // a tiny amount of ambient room light even over a black picture.
        color = mix(color, float3(luminance) * float3(0.92, 0.84, 0.68),
                    grime * 0.42);
        color *= 1.0 - grime * 0.34;
        color += float3(0.10, 0.085, 0.055)
               * (film * 0.025 + smudge * 0.055 + moisture * 0.045);
        color *= 1.0 - mote * 0.58;
        color *= mix(float3(1.0), fleckTransmission, darkFleck * 0.88);
        color *= 1.0 - materialOpacity * 0.30;
        color = mix(color, materialDirt.rgb, materialOpacity * 0.62);
        color += float3(0.18, 0.15, 0.10) * moisture * 0.028;
        return clamp(color, 0.0, 1.0);
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

        float lumaSoft = rf > 0.5 ? 0.85 : 0.55; // tap spacing; wider on RF
        float chromaStep = rf > 0.5 ? 1.85 : 1.35; // broad color bleed

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
        float ghostAmount = rf > 0.5 ? 0.07 : 0.035;
        float3 ghost = sampleBilinear(uv + float2(texelX * 5.0, 0), indexTex, paletteTex).rgb;
        y = mix(y, dot(ghost, float3(0.299, 0.587, 0.114)), ghostAmount);

        // Chroma: very wide asymmetric horizontal average — color bandwidth
        // collapses, arrives late and bleeds well beyond sharp luma edges.
        float2 iq = float2(0.0);
        float wsum = 0.0;
        float chromaFalloff = rf > 0.5 ? 0.16 : 0.20;
        for (int k = -2; k <= 6; k++) {
            float shifted = float(k) - 0.7;
            float w = exp(-chromaFalloff * shifted * shifted);
            float3 s = sampleBilinear(uv + float2(texelX * float(k) * chromaStep, 0), indexTex, paletteTex).rgb;
            float3 yiq = toYIQ(s);
            iq += w * yiq.yz;
            wsum += w;
        }
        iq /= wsum;

        // Cross-color: imperfect composite Y/C separation interprets fine
        // high-contrast luma detail as color subcarrier. This is what gives
        // bright text and narrow lines the photographed red/green/blue edge
        // fringes even when the source pixels themselves are white. Anchor
        // phase to source pixels (not output resolution), and alternate Q on
        // successive PAL lines. A wider gradient term lets the false color
        // bleed just beyond each edge rather than forming a hard rainbow grid.
        float centerY = dot(
            sampleBilinear(uv, indexTex, paletteTex).rgb,
            float3(0.299, 0.587, 0.114));
        float leftY = dot(cl, float3(0.299, 0.587, 0.114));
        float rightY = dot(cr, float3(0.299, 0.587, 0.114));
        float highFrequency = abs(centerY - (leftY + rightY) * 0.5);
        float edgeGradient = rightY - leftY;
        float crossEnergy = clamp(
            highFrequency * 1.45 + abs(edgeGradient) * 0.38,
            0.0, 1.0);
        float2 sourcePos = uv * float2(size);
        float subcarrierPhase = sourcePos.x * 1.5707963;
        float palAlternation =
            (int(floor(sourcePos.y)) & 1) == 0 ? 1.0 : -1.0;
        float2 falseChroma = float2(
            cos(subcarrierPhase),
            sin(subcarrierPhase) * palAlternation);
        falseChroma *= crossEnergy * sign(edgeGradient + 0.0001)
                     * (rf > 0.5 ? 0.14 : 0.11);
        iq += falseChroma;

        // Dot crawl: on chroma transitions, the comb filter fails and a
        // checkerboard of residual subcarrier climbs the edge.
        float3 yiqL = toYIQ(cl), yiqR = toYIQ(cr);
        float chromaEdge = length(yiqR.yz - yiqL.yz);
        float crawl = chromaEdge * (rf > 0.5 ? 0.18 : 0.12) *
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
                           texture2d_array<uint> historyTex,
                           float signal, float time, float phosphorColor,
                           float brightness, float maskPitch,
                           float historyHead, float historyValidCount,
                           float historyPhase) {
        uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
        float3 color;
        if (signal > 0.5) {
            color = compositeSample(uv, pixelPos, indexTex, paletteTex,
                                    signal > 1.5 ? 1.0 : 0.0, time);
        } else {
            color = sampleBilinear(uv, indexTex, paletteTex).rgb;
        }

        // Long-persistence amber phosphor: retain bright luminance from the
        // previous 11 PAL source frames with exponential decay. Source-frame
        // history keeps moving objects trailing for ~240 ms without feeding
        // back dither/noise from the rendered framebuffer.
        if (phosphorColor > 0.5 && phosphorColor < 1.5
            && historyValidCount > 1.0) {
            // Initial emission is read directly from the indexed source
            // texel: exactly one of the C64's 16 palette luminances, with no
            // interpolation or invented digital shade.
            float3 indexedCurrent = sampleIndexedColorNearest(
                uv, indexTex, paletteTex);
            float currentEmission = dot(
                indexedCurrent, float3(0.299, 0.587, 0.114));
            float persistentLuma = currentEmission;
            for (int age = 1; age < 12; age++) {
                if (float(age) >= historyValidCount) {
                    break;
                }
                int slice = int(historyHead) - age;
                if (slice < 0) {
                    slice += 12;
                }
                float3 oldColor = sampleHistoryColor(
                    uv, uint(slice), historyTex, paletteTex);
                float oldLuma = dot(oldColor, float3(0.299, 0.587, 0.114));
                // historyPhase advances continuously between incoming 50 Hz
                // frames, so the temporal decay is analog rather than 12
                // frame-quantized intensity steps.
                float decay = exp(-(float(age) + historyPhase) * 0.16);
                persistentLuma = max(persistentLuma, oldLuma * decay);
            }
            float filteredLuma = dot(color, float3(0.299, 0.587, 0.114));
            color += float3(max(0.0, persistentLuma - filteredLuma));
        }

        // Soft horizontal bloom: neighbours bleed slightly.
        float2 texel = 1.0 / float2(size);
        float3 blur = sampleBilinear(uv + float2(texel.x, 0), indexTex, paletteTex).rgb
                    + sampleBilinear(uv - float2(texel.x, 0), indexTex, paletteTex).rgb;
        float bloomAmount = phosphorColor > 0.5 && phosphorColor < 2.5
                          ? 0.38 : 0.25;
        color = mix(color, blur * 0.5, bloomAmount);

        // Scanlines: darken between source rows, gently, luminance-dependent.
        float row = uv.y * float(size.y);
        float scan = sin(row * 3.14159265 * 2.0) * 0.5 + 0.5;   // 1 at row centers
        float lum = dot(color, float3(0.299, 0.587, 0.114));
        float scanStrength = mix(0.35, 0.15, lum);              // bright areas mask lines
        // Near the top of the brightness control, amber/green tubes emulate
        // beam-current bloom: phosphor light spills vertically into the dark
        // gap and the scanline structure starts glowing together. Keep the
        // normal scanline look through most of the knob's range.
        float monoPhosphor = phosphorColor > 0.5 && phosphorColor < 2.5
                           ? 1.0 : 0.0;
        float beamDrive = smoothstep(0.62, 1.0, brightness)
                        * monoPhosphor;
        scanStrength *= mix(1.0, 0.22, beamDrive);
        color *= mix(1.0 - scanStrength, 1.0, scan);
        color += blur * 0.5 * (1.0 - scan) * beamDrive * 0.18;

        // Shadow-mask phosphor triads at the selected monitor's physical dot
        // pitch. Alternate rows are staggered and vertically modulated into
        // soft oval dots rather than an aperture-grille stripe pattern.
        float pitch = max(maskPitch, 3.0);
        float maskRow = floor(pixelPos.y / (pitch * 0.52));
        float stagger = fmod(maskRow, 2.0) * (pitch / 6.0);
        float phase = fmod(pixelPos.x + stagger, pitch) / pitch;
        int channel = min(2, int(floor(phase * 3.0)));
        float verticalPhase = fract(pixelPos.y / (pitch * 0.52));
        float dotAperture = 0.95 + 0.07
                          * (cos((verticalPhase - 0.5) * 6.2831853)
                             * 0.5 + 0.5);
        float3 mask = channel == 0 ? float3(1.06, 0.95, 0.95)
                    : channel == 1 ? float3(0.95, 1.06, 0.95)
                                   : float3(0.95, 0.95, 1.06);
        color *= mask * dotAperture;

        return color;
    }

    fragment float4 fragmentCRT(VertexOut in [[stage_in]],
                                constant Uniforms &uniforms [[buffer(0)]],
                                texture2d<uint> indexTex [[texture(0)]],
                                texture2d<float> paletteTex [[texture(1)]],
                                texture2d<float> dirtTex [[texture(2)]],
                                texture2d_array<uint> historyTex [[texture(3)]],
                                sampler smp [[sampler(0)]]) {
        float2 sourceUV = dirtyGlassUV(in.texCoord, uniforms);
        float3 color = crtShade(sourceUV, in.position.xy, indexTex,
                                paletteTex, historyTex,
                                uniforms.signal, uniforms.time,
                                uniforms.phosphorColor, uniforms.brightness,
                                uniforms.maskPitch, uniforms.historyHead,
                                uniforms.historyValidCount,
                                uniforms.historyPhase);
        color = applyPhosphorColor(applyPicture(color, uniforms), uniforms);
        color = applyDirtyGlass(color, in.texCoord, in.position.xy,
                                uniforms, dirtTex);
        return float4(dither(color, in.position.xy), 1.0);
    }

    // Signed distance to the tube face: a rounded rect of half-extent 1.
    static float faceSDF(float2 p, float r) {
        float2 q = abs(p) - (1.0 - r);
        return length(max(q, 0.0)) - r;
    }

    // Physical tube glass exists independently of phosphor emission and C64
    // palette black. Keep a cool-neutral charcoal floor that darkens gently
    // toward the curved edges, unaffected by picture controls.
    static float3 tubeGlassBase(float2 cc) {
        float radial = clamp(dot(cc, cc) * 0.5, 0.0, 1.0);
        float level = mix(0.048, 0.026, smoothstep(0.15, 1.0, radial));
        return level * float3(0.96, 0.99, 1.02);
    }

    // Tube variant: barrel distortion, rounded corners, vignette, and a
    // diffuse edge reflection on the angled plastic bezel around the face.
    fragment float4 fragmentCRTTube(VertexOut in [[stage_in]],
                                    constant Uniforms &uniforms [[buffer(0)]],
                                    texture2d<uint> indexTex [[texture(0)]],
                                    texture2d<float> paletteTex [[texture(1)]],
                                    texture2d<float> dirtTex [[texture(2)]],
                                    texture2d_array<uint> historyTex [[texture(3)]],
                                    sampler smp [[sampler(0)]]) {
        // Center coordinates in [-1, 1].
        float2 cc = in.texCoord * 2.0 - 1.0;
        float shutdown = clamp(uniforms.powerOff, 0.0, 1.0);
        float verticalCollapse = smoothstep(0.0, 0.52, shutdown);
        float horizontalCollapse = smoothstep(0.48, 0.80, shutdown);
        float finalFade = smoothstep(0.76, 1.0, shutdown);
        float verticalScale = mix(1.0, 0.006, verticalCollapse);
        float horizontalScale = mix(1.0, 0.004, horizontalCollapse);

        // Barrel distortion: push samples outward toward the edges.
        float2 curved = cc * (1.0 + 0.028 * dot(cc, cc));

        const float radius = 0.08;
        float sd = faceSDF(curved, radius);
        // The inner plastic bezel overlaps the imperfect glass perimeter.
        // Move the visible glass/bezel boundary 1.8% inside the physical tube.
        const float bezelOverlap = 0.018;
        float wallDepth = sd + bezelOverlap;

        if (wallDepth >= 0.0) {
            // ---- Angled inner bezel between glass and monitor case. ----

            // Depth cues: the mask is sunken, so its outer rim (under the
            // case lip) sits in shadow, and light from above leaves the
            // top wall of the recess darker than the bottom. The lip
            // shadow uses a rounded-rect distance — a box metric
            // (max(|x|,|y|)) puts visible diagonal seams in the corners.
            float rimDist = -faceSDF(cc, 0.30);                 // 0 at the outer rim
            float lipShadow = smoothstep(-0.06, 0.30, rimDist); // dark under the lip
            float topShadow = mix(0.62, 1.0, smoothstep(-1.15, -0.25, cc.y));
            float3 standalonePlastic = float3(0.020, 0.021, 0.024);
            float3 c1702Plastic = float3(0.045, 0.034, 0.028);
            float3 c1084Plastic = float3(0.145, 0.135, 0.115);
            float3 plastic = uniforms.bezelSurfaceMode < 0.5
                           ? standalonePlastic
                           : (uniforms.bezelSurfaceMode < 1.5
                              ? c1702Plastic : c1084Plastic);
            float sideShade = mix(0.88, 1.0,
                                  smoothstep(-1.0, 0.65, cc.x));
            float3 base = plastic * lipShadow * topShadow * sideShade;

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
                faceSDF(curved + e.xy, radius)
                    - faceSDF(curved - e.xy, radius),
                faceSDF(curved + e.yx, radius)
                    - faceSDF(curved - e.yx, radius)));
            // The plastic wall is approximately 85° to the tube face (5°
            // from vertical) and overlaps the glass edge slightly. As depth
            // increases, project only tan(5°) farther inward: one continuous
            // mapping that follows the wall without fanning out.
            const float wallLean = 0.0874887; // tan(5°)
            float2 edgePoint = curved
                - (wallDepth + 0.012 + wallDepth * wallLean) * n;
            float2 uvr = clamp(edgePoint * 0.5 + 0.5, 0.0, 1.0);

            // Perspective from a viewer centered in front of the tube. The
            // midpoint of each wall has no screen-space shear and is most
            // front-facing; toward corners, reflection rays bend progressively
            // back toward the horizontal/vertical screen centerline.
            bool sideWall = abs(n.x) > abs(n.y);
            float alongWall = sideWall ? cc.y : cc.x;
            float2 perspectiveWarp = sideWall
                ? float2(0.0, -cc.y * wallDepth * 0.055)
                : float2(-cc.x * wallDepth * 0.055, 0.0);
            uvr = clamp(uvr + perspectiveWarp, 0.0, 1.0);
            float viewFacing = 1.0 - min(abs(alongWall), 1.0) * 0.18;

            // Rough plastic diffuses the one-to-one projected sample by at
            // most ~1.5 source pixels along the wall tangent. The symmetric,
            // three-tap kernel has one center path and a continuous blur—no
            // widening multi-path branches.
            float2 sourceTexel = 1.0 / float2(
                indexTex.get_width(), indexTex.get_height());
            float2 tangent = float2(n.y, -n.x);
            float roughness = smoothstep(0.0, 0.30, wallDepth);
            float2 tangentOffset = tangent * sourceTexel
                * (0.25 + roughness * 0.55);
            // Reflect a narrow physical strip under the overlapping lip, not
            // only its outermost pixel. These normal offsets correspond to
            // approximately 1.5, 3.2 and 4.8 mm on a 13-inch tube.
            // Equal physical distance on a 4:3 tube: horizontal UV spans
            // ~264 mm, vertical UV ~198 mm.
            float2 inwardUV = n * float2(0.006, 0.008);
            float3 refl = roughReflectionSample(
                uvr, tangentOffset, indexTex, paletteTex) * 0.62;
            refl += roughReflectionSample(
                clamp(uvr - inwardUV, 0.0, 1.0),
                tangentOffset, indexTex, paletteTex) * 0.27;
            refl += roughReflectionSample(
                clamp(uvr - inwardUV * 2.0, 0.0, 1.0),
                tangentOffset, indexTex, paletteTex) * 0.11;
            float reflLuma = dot(refl, float3(0.299, 0.587, 0.114));
            refl = mix(refl, float3(reflLuma), roughness * 0.07);

            refl = applyPhosphorColor(applyPicture(refl, uniforms), uniforms);
            refl *= 1.0 - smoothstep(0.08, 0.58, shutdown);

            // Bloom: soft-knee boost so bright content flares while dark
            // content stays subtle.
            refl += refl * refl * 0.35;

            // The overlapping plastic lip blocks reflection immediately at
            // the glass edge; light then appears on the angled wall and
            // diffuses farther outward with a broad exponential falloff.
            float overlapReveal = smoothstep(0.001, 0.012, wallDepth);
            base *= mix(0.90, 1.0,
                        smoothstep(0.0, 0.014, wallDepth));
            float fade = overlapReveal * exp(-wallDepth * 4.2);
            float3 color = base + refl * fade * 0.297
                         * viewFacing * mix(0.55, 1.0, lipShadow) * topShadow;
            return float4(dither(color, in.position.xy), 1.0);
        }

        // ---- Tube face ----
        float2 glassUV = curved * 0.5 + 0.5;
        // Soft antialiased edge just inside the border.
        float edge = 1.0 - smoothstep(-0.006, 0.0, wallDepth);
        float vig = 1.0 - 0.22 * dot(cc, cc);
        float3 glassBase = tubeGlassBase(cc);

        bool insideCollapsedPicture =
            abs(cc.x) <= horizontalScale && abs(cc.y) <= verticalScale;
        if (!insideCollapsedPicture || finalFade >= 1.0) {
            // The phosphor has collapsed away, but the physical dirty glass
            // remains visible as an almost-black tube face.
            float3 darkGlass = applyDirtyGlass(
                glassBase, glassUV, in.position.xy,
                uniforms, dirtTex);
            return float4(dither(darkGlass * edge, in.position.xy), 1.0);
        }

        // Squeeze the complete last frame into the shrinking beam region.
        float2 contentCC = cc / float2(horizontalScale, verticalScale);
        float2 contentCurved = contentCC
            * (1.0 + 0.028 * dot(contentCC, contentCC));
        float2 uv = clamp(contentCurved * 0.5 + 0.5, 0.0, 1.0);
        // Dirt/refraction stays fixed to physical glass while content moves.
        float2 glassWarp = dirtyGlassUV(glassUV, uniforms) - glassUV;
        float2 sourceUV = clamp(uv + glassWarp, 0.0, 1.0);

        float3 color = applyPhosphorColor(
            applyPicture(crtShade(sourceUV, in.position.xy, indexTex,
                                  paletteTex, historyTex,
                                  uniforms.signal, uniforms.time,
                                  uniforms.phosphorColor, uniforms.brightness,
                                  uniforms.maskPitch, uniforms.historyHead,
                                  uniforms.historyValidCount,
                                  uniforms.historyPhase),
                         uniforms),
            uniforms);

        // Flyback collapse concentrates beam energy into a bright horizontal
        // line, then a hot center dot, before the high voltage drains away.
        float lineWidth = max(verticalScale * 0.55, 0.002);
        float lineCore = exp(-pow(abs(cc.y) / lineWidth, 2.0) * 2.5);
        float dotRadius = max(horizontalScale * 0.70, 0.003);
        float dotCore = exp(-dot(cc, cc)
                            / max(dotRadius * dotRadius, 0.00001) * 2.2);
        float beamGain = 1.0 + verticalCollapse * 1.15
                       + horizontalCollapse * 0.85;
        color *= beamGain * vig;
        color += float3(lineCore * verticalCollapse * 0.20);
        color += float3(dotCore * horizontalCollapse * 0.32);
        color *= 1.0 - finalFade;
        // Phosphor light is emitted over, not substituted for, the physical
        // glass. Screen blending preserves the glass floor under signal black.
        color = glassBase + color * (1.0 - glassBase);
        color = applyDirtyGlass(color, glassUV, in.position.xy,
                                uniforms, dirtTex);

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
        self.renderView = mtkView

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Normal video is demand-driven. RF/power-off effects opt into a
        // small animation timer below instead of every surface rendering
        // continuously at 60 FPS while nothing has changed.
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
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

        let historyDesc = MTLTextureDescriptor()
        historyDesc.textureType = .type2DArray
        historyDesc.pixelFormat = .r8Uint
        historyDesc.width = VideoReceiver.width
        historyDesc.height = VideoReceiver.height
        historyDesc.depth = 1
        historyDesc.mipmapLevelCount = 1
        historyDesc.arrayLength = Self.historyFrameCount
        historyDesc.sampleCount = 1
        historyDesc.storageMode = .shared
        historyDesc.usage = [.shaderRead]
        guard let history = device.makeTexture(descriptor: historyDesc) else {
            return nil
        }
        self.historyTexture = history

        // Palette texture: 16x1 RGBA.
        let paletteDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 16,
            height: 1,
            mipmapped: false)
        paletteDesc.usage = [.shaderRead]
        guard let paletteTex = device.makeTexture(descriptor: paletteDesc) else { return nil }
        self.paletteTexture = paletteTex

        let dirtLoader = MTKTextureLoader(device: device)
        // A packaged .app places the texture in Contents/Resources. `swift
        // run` keeps it in SwiftPM's generated resource bundle instead.
        var dirtURL = Bundle.main.url(
            forResource: "dirty-glass-mask", withExtension: "png")
        if dirtURL == nil, !ResourceBundle.isPackagedApp {
            dirtURL = Bundle.module.url(
                forResource: "dirty-glass-mask", withExtension: "png")
        }
        if let url = dirtURL,
           let texture = try? dirtLoader.newTexture(
            URL: url,
            options: [
                .SRGB: false,
                .origin: MTKTextureLoader.Origin.topLeft,
            ]) {
            self.dirtyGlassTexture = texture
        } else {
            // Missing resources must not make the entire renderer fail. A
            // transparent fallback leaves the procedural dirt layers active.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 1, height: 1, mipmapped: false)
            descriptor.usage = [.shaderRead]
            guard let fallback = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            var transparent: UInt32 = 0
            fallback.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: &transparent,
                bytesPerRow: 4)
            self.dirtyGlassTexture = fallback
        }

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
        textureLock.lock()
        palettePendingBytes = bytes
        textureLock.unlock()
    }

    func beginPowerOffEffect() {
        powerOffEffectStartedAt = DispatchTime.now().uptimeNanoseconds
        updateAnimationTimer(enabled: true)
    }

    func cancelPowerOffEffect() {
        powerOffEffectStartedAt = nil
        updateAnimationTimer(enabled: signalLevel >= 2)
    }

    func requestRedraw() {
        let redraw = { [weak self] in
            guard let self, let renderView = self.renderView else { return }
            renderView.setNeedsDisplay(renderView.bounds)
        }
        if Thread.isMainThread {
            redraw()
        } else {
            DispatchQueue.main.async(execute: redraw)
        }
    }

    private func scheduleDeferredRedraw() {
        guard !deferredRedrawPending else { return }
        deferredRedrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredRedrawPending = false
            self.requestRedraw()
        }
    }

    /// Updates the RF animation timer. Returns whether the enabled state
    /// changed so callers can avoid redundant redraws.
    @discardableResult
    func updateAnimationState() -> Bool {
        let wantTimer = signalLevel >= 2 || powerOffEffectStartedAt != nil
        let wasRunning = animationTimer != nil
        updateAnimationTimer(enabled: wantTimer)
        let changed = wantTimer != wasRunning
        if changed {
            requestRedraw()
        }
        return changed
    }

    private func updateAnimationTimer(enabled: Bool) {
        if enabled {
            guard animationTimer == nil else { return }
            let timer = Timer(
                timeInterval: 1.0 / 30.0,
                repeats: true) { [weak self] _ in
                self?.requestRedraw()
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
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
        guard pendingScreenshotCompletion == nil else {
            completion(nil)
            return
        }
        pendingScreenshotCompletion = completion
        requestRedraw()
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
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else {
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
        encoder.setFragmentTexture(dirtyGlassTexture, index: 2)
        encoder.setFragmentTexture(historyTexture, index: 3)
        encoder.setFragmentSamplerState(filterMode == .sharp ? nearestSampler : linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { _ in
            let image = Self.readScreenshotTexture(
                target: target,
                width: width,
                height: height)
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Reads the offscreen texture back to CPU. Called from the command
    /// buffer's completion handler (an arbitrary Metal-internal thread) —
    /// safe because that handler only fires once the GPU has finished
    /// writing, and nothing else touches this texture concurrently for the
    /// brief window between encoding and readback.
    private static func readScreenshotTexture(
        target: MTLTexture,
        width: Int,
        height: Int
    ) -> CGImage? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        target.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0)
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
        let now = DispatchTime.now()
        if let lastFrameSubmission,
           now.uptimeNanoseconds - lastFrameSubmission.uptimeNanoseconds
                > 500_000_000 {
            resetHistoryOnNextFrame = true
        }
        lastFrameSubmission = now
        pendingFrame = frame
        if Self.debug {
            dbgSubmitted += 1
            if dbgSubmitted % 100 == 1 {
                NSLog("[render] submitted=%d drawn=%d", dbgSubmitted, dbgDrawn)
            }
        }
        textureLock.unlock()
        requestRedraw()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func noteSemaphoreMiss() {
        recentSemaphoreMisses = min(recentSemaphoreMisses + 1, 8)
        publishBehindFlagIfChanged()
    }

    private func noteSuccessfulPresent() {
        if recentSemaphoreMisses > 0 {
            recentSemaphoreMisses -= 1
        }
        let now = DispatchTime.now()
        if let last = lastSuccessfulPresentTime {
            let gap = Double(now.uptimeNanoseconds - last.uptimeNanoseconds)
                / 1_000_000_000
            let recentlyFed = lastFrameSubmission.map {
                Double(now.uptimeNanoseconds - $0.uptimeNanoseconds)
                    / 1_000_000_000 < 0.15
            } ?? false
            // ~50 Hz stream → 20 ms gaps. Sustained >~24 ms means the
            // demand-driven CRT path is losing main-run-loop time to
            // secondary visualizations even when the GPU semaphore is free.
            if recentlyFed, gap > (1.0 / 42.0), gap < 0.25 {
                slowPresentStreak = min(slowPresentStreak + 1, 10)
            } else if gap <= (1.0 / 48.0) {
                slowPresentStreak = max(0, slowPresentStreak - 2)
            }
        }
        lastSuccessfulPresentTime = now
        publishBehindFlagIfChanged()
        presentCount += 1
        let elapsed = Double(now.uptimeNanoseconds - lastPresentStatsTime.uptimeNanoseconds)
            / 1_000_000_000
        guard elapsed >= 1.0 else { return }
        let fps = Double(presentCount) / elapsed
        presentCount = 0
        lastPresentStatsTime = now
        lastReportedPresentFPS = fps
        onLoadStats?(fps, isGPUBehind)
    }

    private func publishBehindFlagIfChanged() {
        let behind = recentSemaphoreMisses >= 2 || slowPresentStreak >= 3
        guard behind != isGPUBehind else { return }
        isGPUBehind = behind
        onLoadStats?(lastReportedPresentFPS, behind)
    }

    func draw(in view: MTKView) {
        guard inFlightSemaphore.wait(timeout: .now()) == .success else {
            // Let the GPU catch up instead of overwriting in-flight textures,
            // but schedule one deferred redraw so a pending frame is not stuck
            // until the next UDP packet or RF timer tick.
            noteSemaphoreMiss()
            scheduleDeferredRedraw()
            return
        }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor) else {
            inFlightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        // Upload the most recent frame, if any.
        textureLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        let resetHistory = resetHistoryOnNextFrame
        resetHistoryOnNextFrame = false
        let palette = palettePendingBytes
        palettePendingBytes = nil
        textureLock.unlock()

        if let palette,
           let replacement = Self.makePaletteTexture(
                device: device, bytes: palette) {
            // Never mutate a palette texture already referenced by an
            // in-flight command buffer. Replacing the object keeps the old
            // texture alive through Metal's command-buffer retention.
            paletteTexture = replacement
        }

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
            if resetHistory {
                historyHead = 0
                historyValidCount = 0
            }
            historyHead = (historyHead + 1) % Self.historyFrameCount
            historyValidCount = min(
                historyValidCount + 1, Self.historyFrameCount)
            historyLastUploadUptime = DispatchTime.now().uptimeNanoseconds
            frame.withUnsafeBytes { raw in
                indexTextures[currentTextureIndex].replace(
                    region: MTLRegionMake2D(0, 0, VideoReceiver.width, VideoReceiver.height),
                    mipmapLevel: 0,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: VideoReceiver.width)
                historyTexture.replace(
                    region: MTLRegionMake2D(
                        0, 0, VideoReceiver.width, VideoReceiver.height),
                    mipmapLevel: 0,
                    slice: historyHead,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: VideoReceiver.width,
                    bytesPerImage: VideoReceiver.width * VideoReceiver.height)
            }
        }

        let pipeline: MTLRenderPipelineState
        switch filterMode {
        case .sharp: pipeline = sharpPipeline
        case .smooth: pipeline = smoothPipeline
        case .crt: pipeline = crtPipeline
        case .crtTube: pipeline = crtTubePipeline
        }

        frameIndex &+= 1
        let scale = computeScale(drawableSize: view.drawableSize)
        // Both monitors use a nominal 13-inch 4:3 tube (~264.2 mm visible
        // width). Convert physical dot pitch to destination pixels after
        // letterboxing; clamp to one RGB triad when the view is too small to
        // resolve the requested pitch without severe aliasing.
        let pictureWidthPixels = Float(view.drawableSize.width) * scale.x
        let maskPitch = max(
            3.0,
            monitorDotPitchMillimeters * pictureWidthPixels / 264.2)
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedSinceSourceFrame = historyLastUploadUptime == 0
            ? 0
            : Float(now - historyLastUploadUptime) / 1_000_000_000
        let historyPhase = min(elapsedSinceSourceFrame * 50.0, 100.0)
        let powerOffProgress: Float
        if let powerOffEffectStartedAt {
            let elapsed = Float(now - powerOffEffectStartedAt)
                / 1_000_000_000
            powerOffProgress = min(elapsed / 0.9, 1.0)
        } else {
            powerOffProgress = 0
        }
        var uniforms = Uniforms(scale: scale,
                                reflection: reflectionEnabled ? 1 : 0,
                                signal: signalLevel,
                                time: Float(frameIndex % 3600) / 60.0,
                                brightness: picture?.brightness ?? 0.5,
                                contrast: picture?.contrast ?? 0.5,
                                saturation: picture?.saturation ?? 0.5,
                                tint: picture?.tint ?? 0.5,
                                phosphorColor: crtScreenColor.shaderValue,
                                dirtyGlass: crtDirtyGlass ? 1 : 0,
                                maskPitch: maskPitch,
                                historyHead: Float(historyHead),
                                historyValidCount: Float(historyValidCount),
                                historyPhase: historyPhase,
                                powerOff: powerOffProgress,
                                bezelSurfaceMode: bezelSurfaceMode)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(indexTextures[currentTextureIndex], index: 0)
        encoder.setFragmentTexture(paletteTexture, index: 1)
        encoder.setFragmentTexture(dirtyGlassTexture, index: 2)
        encoder.setFragmentTexture(historyTexture, index: 3)
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
        noteSuccessfulPresent()
    }

    deinit {
        animationTimer?.invalidate()
    }

    private static func makePaletteTexture(
        device: MTLDevice,
        bytes: [UInt8]
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 16,
            height: 1,
            mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, 16, 1),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: 64)
        return texture
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
