import Foundation
import Metal
import MetalKit
import QuartzCore
import CoreGraphics
import CoreVideo
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
    /// (~240 ms at PAL 50 fps / NTSC 60 fps).
    private var historyTexture: MTLTexture
    private var historyHead = 0
    private var historyValidCount = 0
    private var historyLastUploadUptime: UInt64 = 0
    /// Live stream height in pixels (272 PAL / 240 NTSC). Textures resize
    /// when the Ultimate switches video standard.
    private var sourceFrameHeight = VideoReceiver.palHeight
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
    /// Ordered source frames waiting for the present queue. A single slot was
    /// overwriting mid-scroll frames (visible jumps); keep a few in order.
    private var pendingFrames: [Data] = []
    private static let maxPendingFrames = 3
    private var resetHistoryOnNextFrame = false
    private var lastFrameSubmission: DispatchTime?
    /// While UDP frames are arriving, run the MTKView display link at the
    /// panel rate. For PAL (~50 Hz) onto a 60 Hz panel, temporally blend
    /// consecutive frames (1-frame delay) so scrolltext stays continuous.
    /// NTSC (~60 Hz) matches typical panels — hard cuts, no blend.
    private var isLivePresentMode = false
    /// Mirrors live mode for the UDP thread so `submitFrame` only hops to
    /// main when *entering* live present (not on every PAL/NTSC frame).
    private var livePresentArmed = false
    /// Leave live mode shortly after the stream goes quiet so idle viewers
    /// do not keep burning CRT shaders at refresh rate.
    private static let livePresentIdleSeconds: Double = 0.18
    /// Nominal content interval from the active video standard.
    private var streamPresentInterval: Double {
        1.0 / contentFrameRate
    }
    private var contentFrameRate: Double {
        sourceFrameHeight <= VideoReceiver.ntscHeight ? 60.0 : 50.0
    }
    private var isNTSCContent: Bool {
        sourceFrameHeight <= VideoReceiver.ntscHeight
    }
    /// Arrival times (uptime ns) of the previous and current source frames.
    private var previousFrameArrivalNs: UInt64 = 0
    private var currentFrameArrivalNs: UInt64 = 0
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
    /// Cumulative queue-loss count, sampled by DeviceSession once per second.
    /// Updated while `textureLock` is held whenever a source frame is skipped.
    private var droppedSourceFrameCount = 0
    /// Main-thread callback with present FPS and display-behind state (~1 Hz,
    /// plus immediate flips of the behind flag).
    var onLoadStats: ((_ presentFPS: Double, _ gpuBehind: Bool) -> Void)?
    /// Set by `requestFilteredScreenshot`, consumed on the next present.
    /// Taken under `textureLock` when the present queue is live.
    private var pendingScreenshotCompletion: ((CGImage?) -> Void)?
    private struct FilteredRecordingRequest {
        let size: FilteredRecordingSize
        /// Supplies a buffer from AVAssetWriter's adaptor pool. Rendering
        /// directly into it avoids handing the writer unrelated IOSurfaces.
        let makePixelBuffer: () -> CVPixelBuffer?
        let consume: (CVPixelBuffer) -> Void
    }
    /// A filtered movie is encoded from this renderer's source textures, not
    /// from the drawable. This keeps recording available while the view is
    /// occluded and avoids a second display-sized readback.
    private var filteredRecordingRequest: FilteredRecordingRequest?
    private var metalTextureCache: CVMetalTextureCache?
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
    /// Fires after the stream goes quiet so live mode can pause the link.
    private var livePresentIdleTimer: Timer?
    /// Drawable size mirrored from MTKView.
    private var cachedDrawableSize: CGSize = .zero
    /// Frame counter driving RF noise animation.
    private var frameIndex: UInt32 = 0
    /// Live picture controls, read every frame (bypasses SwiftUI updates
    /// so knob drags adjust the picture without re-rendering views).
    var picture: PictureControls?
    /// CRT optics knobs (scanlines/bloom/mask/barrel), same live-bypass pattern.
    var optics: CRTOpticsControls?

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
        var scanlineStrength: Float
        var bloomAmount: Float
        var maskIntensity: Float
        var barrelDistortion: Float
        /// 0…1 mix from previous PAL frame → current, for 50→60 display
        /// resampling (1-frame delayed). 1 = current only.
        var motionBlend: Float
    }

    private struct PresentationUniforms {
        var scale: SIMD2<Float>
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
        float scanlineStrength;
        float bloomAmount;
        float maskIntensity;
        float barrelDistortion;
        float motionBlend;
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

    vertex VertexOut vertexPresent(uint vid [[vertex_id]],
                                   constant float2 &scale [[buffer(0)]]) {
        float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 texCoords[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        VertexOut out;
        out.position = float4(positions[vid] * scale, 0, 1);
        out.texCoord = texCoords[vid];
        return out;
    }

    fragment float4 fragmentPresent(
        VertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        sampler sourceSampler [[sampler(0)]]
    ) {
        return source.sample(sourceSampler, in.texCoord);
    }

    // ---- Sampling helpers (shared by sharp / smooth / CRT) ----

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

    // Same bilinear kernel as sampleBilinear, but from a history slice —
    // required so 50→60 motion blend does not mix nearest into bilinear
    // (that mismatch flickered CRT bloom/scanlines every blend step).
    static float4 sampleHistoryBilinear(
        float2 uv, uint slice,
        texture2d_array<uint> historyTex,
        texture2d<float> paletteTex) {
        uint2 size = uint2(historyTex.get_width(), historyTex.get_height());
        float2 pos = uv * float2(size) - 0.5;
        float2 f = fract(pos);
        int2 base = int2(floor(pos));
        float4 c[4];
        for (int i = 0; i < 4; i++) {
            int2 offset = int2(i & 1, i >> 1);
            uint2 coord = uint2(clamp(base + offset, int2(0), int2(size) - 1));
            uint index = historyTex.read(coord, slice).r;
            c[i] = paletteTex.read(uint2(index, 0));
        }
        float4 top = mix(c[0], c[1], f.x);
        float4 bottom = mix(c[2], c[3], f.x);
        return mix(top, bottom, f.y);
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

    // Previous PAL history slice for 50→60 motion resampling.
    static uint previousHistorySlice(constant Uniforms &u) {
        int slice = int(u.historyHead) - 1;
        if (slice < 0) {
            slice += 12;
        }
        return uint(slice);
    }

    static float3 applyMotionBlendNearest(
        float3 current, float2 uv,
        texture2d_array<uint> historyTex,
        texture2d<float> paletteTex,
        constant Uniforms &u) {
        if (u.motionBlend >= 0.999 || u.historyValidCount < 2.0) {
            return current;
        }
        float3 previous = sampleHistoryColor(
            uv, previousHistorySlice(u), historyTex, paletteTex);
        return mix(previous, current, u.motionBlend);
    }

    static float3 applyMotionBlendBilinear(
        float3 current, float2 uv,
        texture2d_array<uint> historyTex,
        texture2d<float> paletteTex,
        constant Uniforms &u) {
        if (u.motionBlend >= 0.999 || u.historyValidCount < 2.0) {
            return current;
        }
        float3 previous = sampleHistoryBilinear(
            uv, previousHistorySlice(u), historyTex, paletteTex).rgb;
        return mix(previous, current, u.motionBlend);
    }

    fragment float4 fragmentMain(VertexOut in [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]],
                                 texture2d<uint> indexTex [[texture(0)]],
                                 texture2d<float> paletteTex [[texture(1)]],
                                 texture2d<float> dirtTex [[texture(2)]],
                                 texture2d_array<uint> historyTex [[texture(3)]],
                                 sampler smp [[sampler(0)]]) {
        (void)dirtTex;
        uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
        uint2 coord = uint2(in.texCoord * float2(size));
        coord = min(coord, size - 1);
        uint index = indexTex.read(coord).r;
        float3 rgb = paletteTex.read(uint2(index, 0)).rgb;
        rgb = applyMotionBlendNearest(
            rgb, in.texCoord, historyTex, paletteTex, uniforms);
        return float4(applyPicture(rgb, uniforms), 1.0);
    }

    // Smooth variant: sample palette-expanded neighbors with manual bilinear blend.
    fragment float4 fragmentSmooth(VertexOut in [[stage_in]],
                                   constant Uniforms &uniforms [[buffer(0)]],
                                   texture2d<uint> indexTex [[texture(0)]],
                                   texture2d<float> paletteTex [[texture(1)]],
                                   texture2d<float> dirtTex [[texture(2)]],
                                   texture2d_array<uint> historyTex [[texture(3)]],
                                   sampler smp [[sampler(0)]]) {
        (void)dirtTex;
        float3 rgb = sampleBilinear(in.texCoord, indexTex, paletteTex).rgb;
        rgb = applyMotionBlendBilinear(
            rgb, in.texCoord, historyTex, paletteTex, uniforms);
        return float4(applyPicture(rgb, uniforms), 1.0);
    }

    // ---- CRT helpers ----

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

    // CRT optics knobs are 0...1 with neutral at 0.5 (= 1× historical look).
    // Below center scales 0...1×; above center ramps to maxGain× so the
    // right half of each Pro knob has useful headroom.
    static float opticsGain(float knob, float maxGain) {
        float t = saturate(knob) * 2.0;
        return t <= 1.0 ? t : mix(1.0, maxGain, t - 1.0);
    }

    // Scanlines + phosphor triads + subtle bloom, applied to a flat image.
    // signal: 0 = S-Video (clean), 1 = composite, 2 = RF (composite + noise).
    static float3 crtShade(float2 uv, float2 pixelPos,
                           texture2d<uint> indexTex,
                           texture2d<float> paletteTex,
                           texture2d_array<uint> historyTex,
                           constant Uniforms &u,
                           float signal, float time, float phosphorColor,
                           float brightness, float maskPitch,
                           float historyHead, float historyValidCount,
                           float historyPhase,
                           float scanlineAmount, float bloomAmount,
                           float maskIntensity) {
        uint2 size = uint2(indexTex.get_width(), indexTex.get_height());
        uint prevSlice = previousHistorySlice(u);
        float blend = (u.historyValidCount >= 2.0) ? u.motionBlend : 1.0;
        float3 color;
        if (signal > 0.5) {
            // Composite/RF noise is current-frame only; blending strobes snow.
            color = compositeSample(uv, pixelPos, indexTex, paletteTex,
                                    signal > 1.5 ? 1.0 : 0.0, time);
            blend = 1.0;
        } else {
            float3 current = sampleBilinear(uv, indexTex, paletteTex).rgb;
            if (blend < 0.999) {
                float3 previous = sampleHistoryBilinear(
                    uv, prevSlice, historyTex, paletteTex).rgb;
                color = mix(previous, current, blend);
            } else {
                color = current;
            }
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
            if (blend < 0.999) {
                indexedCurrent = mix(
                    sampleHistoryColor(uv, prevSlice, historyTex, paletteTex),
                    indexedCurrent, blend);
            }
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

        // Soft horizontal bloom: neighbours bleed slightly. Knob 0.5 keeps
        // the historical hardcoded strength (0.25 color / 0.38 mono);
        // above center can push up to 4× that blend (plus a little add).
        float2 texel = 1.0 / float2(size);
        float3 blur = sampleBilinear(uv + float2(texel.x, 0), indexTex, paletteTex).rgb
                    + sampleBilinear(uv - float2(texel.x, 0), indexTex, paletteTex).rgb;
        if (blend < 0.999) {
            float3 blurPrev =
                sampleHistoryBilinear(uv + float2(texel.x, 0), prevSlice,
                                      historyTex, paletteTex).rgb
              + sampleHistoryBilinear(uv - float2(texel.x, 0), prevSlice,
                                      historyTex, paletteTex).rgb;
            blur = mix(blurPrev, blur, blend);
        }
        float bloomBase = phosphorColor > 0.5 && phosphorColor < 2.5
                        ? 0.38 : 0.25;
        float bloomGain = opticsGain(bloomAmount, 4.0);
        float bloom = saturate(bloomBase * bloomGain);
        color = mix(color, blur * 0.5, bloom);
        if (bloomGain > 1.0) {
            color += blur * 0.5 * bloomBase * (bloomGain - 1.0) * 0.28;
        }

        // Scanlines: darken between source rows, gently, luminance-dependent.
        float row = uv.y * float(size.y);
        float scan = sin(row * 3.14159265 * 2.0) * 0.5 + 0.5;   // 1 at row centers
        float lum = dot(color, float3(0.299, 0.587, 0.114));
        float scanStrength = mix(0.35, 0.15, lum)
                           * opticsGain(scanlineAmount, 4.0);
        scanStrength = min(scanStrength, 0.95);
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
        // Gain multiplies triad deviation so values above center actually
        // deepen the mask (the old *2 saturate made 0.5...1.0 identical).
        float maskGain = opticsGain(maskIntensity, 4.0);
        float3 maskColor = mask * dotAperture;
        color *= float3(1.0) + (maskColor - float3(1.0)) * maskGain;

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
                                paletteTex, historyTex, uniforms,
                                uniforms.signal, uniforms.time,
                                uniforms.phosphorColor, uniforms.brightness,
                                uniforms.maskPitch, uniforms.historyHead,
                                uniforms.historyValidCount,
                                uniforms.historyPhase,
                                uniforms.scanlineStrength,
                                uniforms.bloomAmount,
                                uniforms.maskIntensity);
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
        // Knob 0.5 keeps the historical 0.028 coefficient; max ~4×.
        float barrel = 0.028
                     * opticsGain(uniforms.barrelDistortion, 4.0);
        float2 curved = cc * (1.0 + barrel * dot(cc, cc));

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
        float contentBarrel = 0.028
            * opticsGain(uniforms.barrelDistortion, 4.0);
        float2 contentCurved = contentCC
            * (1.0 + contentBarrel * dot(contentCC, contentCC));
        float2 uv = clamp(contentCurved * 0.5 + 0.5, 0.0, 1.0);
        // Dirt/refraction stays fixed to physical glass while content moves.
        float2 glassWarp = dirtyGlassUV(glassUV, uniforms) - glassUV;
        float2 sourceUV = clamp(uv + glassWarp, 0.0, 1.0);

        float3 color = applyPhosphorColor(
            applyPicture(crtShade(sourceUV, in.position.xy, indexTex,
                                  paletteTex, historyTex, uniforms,
                                  uniforms.signal, uniforms.time,
                                  uniforms.phosphorColor, uniforms.brightness,
                                  uniforms.maskPitch, uniforms.historyHead,
                                  uniforms.historyValidCount,
                                  uniforms.historyPhase,
                                  uniforms.scanlineStrength,
                                  uniforms.bloomAmount,
                                  uniforms.maskIntensity),
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
    private let presentPipeline: MTLRenderPipelineState

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.renderView = mtkView
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess,
              let textureCache else { return nil }
        self.metalTextureCache = textureCache

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Idle / disconnected: demand-driven. While UDP frames arrive, live
        // mode unpauses the display link at panel refresh and motion-blends
        // consecutive PAL frames (see submitFrame / motionBlend).
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.preferredFramesPerSecond = 60
        cachedDrawableSize = mtkView.drawableSize

        // Compile shaders.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            NSLog("[render] shader compile FAILED: %@", String(describing: error))
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "vertexMain"),
              let presentVertexFn = library.makeFunction(name: "vertexPresent"),
              let fragmentSharp = library.makeFunction(name: "fragmentMain"),
              let fragmentSmooth = library.makeFunction(name: "fragmentSmooth"),
              let fragmentCRT = library.makeFunction(name: "fragmentCRT"),
              let fragmentCRTTube = library.makeFunction(name: "fragmentCRTTube"),
              let presentFragmentFn = library.makeFunction(name: "fragmentPresent") else {
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

        func makePresentPipeline() -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = presentVertexFn
            descriptor.fragmentFunction = presentFragmentFn
            descriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let sharp = makePipeline(fragment: fragmentSharp),
              let smooth = makePipeline(fragment: fragmentSmooth),
              let crt = makePipeline(fragment: fragmentCRT),
              let crtTube = makePipeline(fragment: fragmentCRTTube),
              let present = makePresentPipeline() else { return nil }
        self.sharpPipeline = sharp
        self.smoothPipeline = smooth
        self.crtPipeline = crt
        self.crtTubePipeline = crtTube
        self.presentPipeline = present
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
        // never touch a texture the GPU is reading. Start at PAL height;
        // NTSC (240) recreates them on the first frame.
        guard let textures = Self.makeIndexTextures(
            device: device, height: VideoReceiver.palHeight),
              let history = Self.makeHistoryTexture(
                device: device, height: VideoReceiver.palHeight) else {
            return nil
        }
        self.indexTextures = textures
        self.historyTexture = history
        self.sourceFrameHeight = VideoReceiver.palHeight

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
            if self.isLivePresentMode, !renderView.isPaused {
                // Display link is already driving presents.
                return
            }
            renderView.setNeedsDisplay(renderView.bounds)
        }
        if Thread.isMainThread {
            redraw()
        } else {
            DispatchQueue.main.async(execute: redraw)
        }
    }

    /// Called by the main-actor session diagnostics sampler. Only the pending
    /// source queue is shared with the UDP callback; all present state belongs
    /// to the main thread.
    func diagnosticsSnapshot() -> MetalRendererDiagnostics {
        textureLock.lock()
        let queuedFrames = pendingFrames.count
        let droppedFrames = droppedSourceFrameCount
        textureLock.unlock()
        return MetalRendererDiagnostics(
            presentFPS: lastReportedPresentFPS,
            queuedFrames: queuedFrames,
            droppedFrames: droppedFrames,
            gpuBehind: isGPUBehind)
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

    /// Unpause the display link for panel-rate presents + motion blend.
    private func enterLivePresentMode() {
        assert(Thread.isMainThread)
        guard let renderView else { return }
        if !isLivePresentMode {
            isLivePresentMode = true
            renderView.enableSetNeedsDisplay = false
            renderView.isPaused = false
            renderView.preferredFramesPerSecond = 60
            if let metalLayer = renderView.layer as? CAMetalLayer {
                // Stay vsync-locked: motion blend needs steady display times.
                metalLayer.displaySyncEnabled = true
                if Self.debug {
                    NSLog("[render] live present: 60Hz vsync + motion blend")
                }
            }
        }
        scheduleLivePresentIdleCheck()
    }

    private func scheduleLivePresentIdleCheck() {
        assert(Thread.isMainThread)
        livePresentIdleTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.livePresentIdleSeconds + 0.02,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.leaveLivePresentModeIfIdle()
            if self.isLivePresentMode {
                self.scheduleLivePresentIdleCheck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        livePresentIdleTimer = timer
    }

    /// Seconds between two uptime stamps. Never traps: a “future” earlier
    /// (clock weirdness, torn cross-thread Optional) yields 0.
    private static func secondsElapsed(
        since earlierNs: UInt64,
        now nowNs: UInt64
    ) -> Double {
        guard nowNs >= earlierNs else { return 0 }
        return Double(nowNs - earlierNs) / 1_000_000_000
    }

    private static func secondsElapsed(
        since earlier: DispatchTime,
        now: DispatchTime = .now()
    ) -> Double {
        secondsElapsed(
            since: earlier.uptimeNanoseconds,
            now: now.uptimeNanoseconds)
    }

    /// Pause the display link once the stream is quiet.
    private func leaveLivePresentModeIfIdle() {
        assert(Thread.isMainThread)
        guard isLivePresentMode else { return }
        textureLock.lock()
        let lastSubmission = lastFrameSubmission
        textureLock.unlock()
        let recentlyFed = lastSubmission.map {
            Self.secondsElapsed(since: $0) < Self.livePresentIdleSeconds
        } ?? false
        guard !recentlyFed else { return }
        isLivePresentMode = false
        textureLock.lock()
        livePresentArmed = false
        textureLock.unlock()
        livePresentIdleTimer?.invalidate()
        livePresentIdleTimer = nil
        guard let renderView else { return }
        renderView.isPaused = true
        renderView.enableSetNeedsDisplay = true
        (renderView.layer as? CAMetalLayer)?.displaySyncEnabled = true
    }

    private var lastEncodedUniforms: Uniforms?

    private func pipelineForCurrentFilter() -> MTLRenderPipelineState {
        switch filterMode {
        case .sharp: return sharpPipeline
        case .smooth: return smoothPipeline
        case .crt: return crtPipeline
        case .crtTube: return crtTubePipeline
        }
    }

    /// 1-frame-delayed blend factor between previous and current source frames.
    /// Disabled for NTSC: content already matches typical 60 Hz panels.
    private func motionBlendFactor(nowNs: UInt64) -> Float {
        guard !isNTSCContent,
              historyValidCount >= 2,
              currentFrameArrivalNs > previousFrameArrivalNs else {
            return 1
        }
        let delayNs = UInt64(streamPresentInterval * 1_000_000_000)
        let contentTime = nowNs > delayNs ? nowNs - delayNs : 0
        if contentTime <= previousFrameArrivalNs { return 0 }
        if contentTime >= currentFrameArrivalNs { return 1 }
        let span = Double(currentFrameArrivalNs - previousFrameArrivalNs)
        return Float(Double(contentTime - previousFrameArrivalNs) / span)
    }

    private func makeUniforms(drawableSize: CGSize) -> Uniforms {
        let scale = computeScale(drawableSize: drawableSize)
        let pictureWidthPixels = Float(drawableSize.width) * scale.x
        let maskPitch = max(
            3.0,
            monitorDotPitchMillimeters * pictureWidthPixels / 264.2)
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedSinceSourceFrame = historyLastUploadUptime == 0
            ? 0
            : Float(Self.secondsElapsed(
                since: historyLastUploadUptime, now: now))
        let historyPhase = min(
            elapsedSinceSourceFrame * Float(contentFrameRate), 100.0)
        let powerOffProgress: Float
        if let powerOffEffectStartedAt {
            let elapsed = Float(Self.secondsElapsed(
                since: powerOffEffectStartedAt, now: now))
            powerOffProgress = min(elapsed / 0.9, 1.0)
        } else {
            powerOffProgress = 0
        }
        // When the CRT path is behind (SID / 3D / multi-viewer), drop the
        // most expensive fragment work so presents can catch up.
        let lite = isGPUBehind
        let bloom = optics?.bloomAmount ?? 0.5
        let histCount = lite
            ? min(historyValidCount, 2) : historyValidCount
        return Uniforms(scale: scale,
                        reflection: reflectionEnabled ? 1 : 0,
                        signal: signalLevel,
                        time: Float(frameIndex % 3600) / 60.0,
                        brightness: picture?.brightness ?? 0.5,
                        contrast: picture?.contrast ?? 0.5,
                        saturation: picture?.saturation ?? 0.5,
                        tint: picture?.tint ?? 0.5,
                        phosphorColor: crtScreenColor.shaderValue,
                        dirtyGlass: (crtDirtyGlass && !lite) ? 1 : 0,
                        maskPitch: maskPitch,
                        historyHead: Float(historyHead),
                        historyValidCount: Float(histCount),
                        historyPhase: historyPhase,
                        powerOff: powerOffProgress,
                        bezelSurfaceMode: bezelSurfaceMode,
                        scanlineStrength: optics?.scanlineStrength ?? 0.5,
                        bloomAmount: lite ? min(bloom, 0.35) : bloom,
                        maskIntensity: optics?.maskIntensity ?? 0.5,
                        barrelDistortion: optics?.barrelDistortion ?? 0.5,
                        motionBlend: lite ? 1 : motionBlendFactor(nowNs: now))
    }

    /// Upload palette/frame and encode the fullscreen pass. Does not end the
    /// encoder or present. Returns whether a new UDP frame was uploaded.
    @discardableResult
    private func encodeFrame(
        encoder: MTLRenderCommandEncoder,
        drawableSize: CGSize,
        frame: Data?,
        resetHistory: Bool,
        palette: [UInt8]?
    ) -> Bool {
        if let palette,
           let replacement = Self.makePaletteTexture(
                device: device, bytes: palette) {
            paletteTexture = replacement
        }

        // Frame uploads happen in `draw(in:)` before this render encoder so
        // history can be filled with a blit. `frame` is unused here.
        _ = frame
        _ = resetHistory
        let uploadedContentFrame = false

        // Advance the shader clock only with content frames so RF/composite
        // noise is not re-seeded on every 60 Hz vsync (visible CRT flicker).
        var uniforms = makeUniforms(drawableSize: drawableSize)
        lastEncodedUniforms = uniforms
        let pipeline = pipelineForCurrentFilter()
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(indexTextures[currentTextureIndex], index: 0)
        encoder.setFragmentTexture(paletteTexture, index: 1)
        encoder.setFragmentTexture(dirtyGlassTexture, index: 2)
        encoder.setFragmentTexture(historyTexture, index: 3)
        encoder.setFragmentSamplerState(
            filterMode == .sharp ? nearestSampler : linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return uploadedContentFrame
    }

    private func uploadFrameData(
        _ frame: Data,
        resetHistory: Bool,
        commandBuffer: MTLCommandBuffer
    ) {
        let height = frame.count / VideoReceiver.width
        guard height > 0,
              frame.count == VideoReceiver.width * height,
              VideoReceiver.isSupportedFrameHeight(height) else {
            return
        }
        var heightChanged = false
        if height != sourceFrameHeight {
            guard ensureSourceTextures(height: height) else { return }
            heightChanged = true
        }
        currentTextureIndex = (currentTextureIndex + 1) % indexTextures.count
        if resetHistory || heightChanged {
            historyHead = 0
            historyValidCount = 0
            previousFrameArrivalNs = 0
            currentFrameArrivalNs = 0
        }
        historyHead = (historyHead + 1) % Self.historyFrameCount
        historyValidCount = min(
            historyValidCount + 1, Self.historyFrameCount)
        let arrival = DispatchTime.now().uptimeNanoseconds
        previousFrameArrivalNs = currentFrameArrivalNs == 0
            ? arrival : currentFrameArrivalNs
        currentFrameArrivalNs = arrival
        historyLastUploadUptime = arrival
        frameIndex &+= 1
        let indexTex = indexTextures[currentTextureIndex]
        frame.withUnsafeBytes { raw in
            indexTex.replace(
                region: MTLRegionMake2D(0, 0, VideoReceiver.width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: VideoReceiver.width)
        }
        // GPU blit into the history array — avoids a second CPU memcpy of
        // the full frame on every present.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: indexTex,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(
                    width: VideoReceiver.width, height: height, depth: 1),
                to: historyTexture,
                destinationSlice: historyHead,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
    }

    /// Recreate index/history textures when the stream switches PAL ↔ NTSC.
    @discardableResult
    private func ensureSourceTextures(height: Int) -> Bool {
        guard let textures = Self.makeIndexTextures(
            device: device, height: height),
              let history = Self.makeHistoryTexture(
                device: device, height: height) else {
            return false
        }
        indexTextures = textures
        historyTexture = history
        currentTextureIndex = 0
        sourceFrameHeight = height
        return true
    }

    private static func makeIndexTextures(
        device: MTLDevice, height: Int
    ) -> [MTLTexture]? {
        let indexDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint,
            width: VideoReceiver.width,
            height: height,
            mipmapped: false)
        // shaderWrite not required for CPU replace; blit source only needs read.
        indexDesc.usage = [.shaderRead]
        indexDesc.storageMode = .shared
        var textures: [MTLTexture] = []
        for _ in 0..<4 {
            guard let tex = device.makeTexture(descriptor: indexDesc) else {
                return nil
            }
            textures.append(tex)
        }
        return textures
    }

    private static func makeHistoryTexture(
        device: MTLDevice, height: Int
    ) -> MTLTexture? {
        let historyDesc = MTLTextureDescriptor()
        historyDesc.textureType = .type2DArray
        historyDesc.pixelFormat = .r8Uint
        historyDesc.width = VideoReceiver.width
        historyDesc.height = height
        historyDesc.depth = 1
        historyDesc.mipmapLevelCount = 1
        historyDesc.arrayLength = historyFrameCount
        historyDesc.sampleCount = 1
        historyDesc.storageMode = .private
        historyDesc.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: historyDesc)
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
        textureLock.lock()
        let busy = pendingScreenshotCompletion != nil
        if !busy {
            pendingScreenshotCompletion = completion
        }
        textureLock.unlock()
        guard !busy else {
            completion(nil)
            return
        }
        requestRedraw()
    }

    /// Begins composited recording. The callback receives a pixel buffer only
    /// after its Metal render pass completes. Returns false if a sensible
    /// output size cannot be formed yet.
    func startFilteredRecording(
        size: FilteredRecordingSize,
        makePixelBuffer: @escaping () -> CVPixelBuffer?,
        consume: @escaping (CVPixelBuffer) -> Void
    ) -> Bool {
        guard let outputSize = filteredRecordingOutputSize(for: size),
              outputSize.width > 0, outputSize.height > 0 else { return false }
        filteredRecordingRequest = FilteredRecordingRequest(
            size: size, makePixelBuffer: makePixelBuffer, consume: consume)
        requestRedraw()
        return true
    }

    func stopFilteredRecording() {
        filteredRecordingRequest = nil
    }

    func filteredRecordingOutputSize(
        for size: FilteredRecordingSize
    ) -> CGSize? {
        switch size {
        case .fourThree:
            return CGSize(width: 768, height: 576)
        case .matchViewer:
            guard cachedDrawableSize.width >= 1,
                  cachedDrawableSize.height >= 1 else { return nil }
            return CGSize(
                width: cachedDrawableSize.width.rounded(.down),
                height: cachedDrawableSize.height.rounded(.down))
        }
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

    private struct FilteredRecordingTarget {
        let pixelBuffer: CVPixelBuffer
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
        let size: CGSize
    }

    /// Wraps a writer-pool IOSurface in a Metal texture. The pixel buffer is
    /// retained through command completion so its texture remains valid until
    /// the writer receives it.
    private func makeFilteredRecordingTarget(
        request: FilteredRecordingRequest
    ) -> FilteredRecordingTarget? {
        guard let outputSize = filteredRecordingOutputSize(for: request.size),
              let pixelBuffer = request.makePixelBuffer(),
              let textureCache = metalTextureCache else {
            return nil
        }
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height else {
            return nil
        }
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture,
              let target = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return FilteredRecordingTarget(
            pixelBuffer: pixelBuffer,
            cvTexture: cvTexture,
            texture: target,
            size: outputSize)
    }

    /// Renders all C64 effects into the writer-owned pixel buffer exactly once.
    private func encodeFilteredRecordingFrame(
        commandBuffer: MTLCommandBuffer,
        target: FilteredRecordingTarget
    ) -> Bool {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: descriptor) else { return false }
        var uniforms = makeUniforms(drawableSize: target.size)
        lastEncodedUniforms = uniforms
        encoder.setRenderPipelineState(pipelineForCurrentFilter())
        encoder.setVertexBytes(
            &uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(
            &uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(indexTextures[currentTextureIndex], index: 0)
        encoder.setFragmentTexture(paletteTexture, index: 1)
        encoder.setFragmentTexture(dirtyGlassTexture, index: 2)
        encoder.setFragmentTexture(historyTexture, index: 3)
        encoder.setFragmentSamplerState(
            filterMode == .sharp ? nearestSampler : linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    /// Copies the already-filtered capture target to the drawable. Fixed 4:3
    /// output is aspect-fit; Match Viewer has identical target/drawable sizes.
    private func encodeFilteredRecordingPresentation(
        commandBuffer: MTLCommandBuffer,
        descriptor: MTLRenderPassDescriptor,
        target: FilteredRecordingTarget,
        drawableSize: CGSize
    ) -> Bool {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: descriptor) else { return false }
        let sourceAspect = Float(target.size.width / target.size.height)
        let drawableAspect = Float(drawableSize.width / drawableSize.height)
        let scale: SIMD2<Float>
        if drawableAspect > sourceAspect {
            scale = SIMD2<Float>(sourceAspect / drawableAspect, 1)
        } else {
            scale = SIMD2<Float>(1, drawableAspect / sourceAspect)
        }
        var uniforms = PresentationUniforms(scale: scale)
        encoder.setRenderPipelineState(presentPipeline)
        encoder.setVertexBytes(
            &uniforms, length: MemoryLayout<PresentationUniforms>.stride,
            index: 0)
        encoder.setFragmentTexture(target.texture, index: 0)
        encoder.setFragmentSamplerState(linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
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
           Self.secondsElapsed(since: lastFrameSubmission, now: now) > 0.5 {
            resetHistoryOnNextFrame = true
        }
        lastFrameSubmission = now
        pendingFrames.append(frame)
        if pendingFrames.count > Self.maxPendingFrames {
            // Drop the oldest still-queued frame; keep temporal order of what
            // remains so scrolltext does not jump backwards.
            pendingFrames.removeFirst()
            droppedSourceFrameCount += 1
        }
        let shouldEnterLive = !livePresentArmed
        if shouldEnterLive { livePresentArmed = true }
        if Self.debug {
            dbgSubmitted += 1
            if dbgSubmitted % 100 == 1 {
                NSLog("[render] submitted=%d drawn=%d queued=%d",
                      dbgSubmitted, dbgDrawn, pendingFrames.count)
            }
        }
        textureLock.unlock()
        // Only hop to main when entering live mode — not 50/60× per second.
        if shouldEnterLive {
            DispatchQueue.main.async { [weak self] in
                self?.enterLivePresentMode()
            }
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        cachedDrawableSize = size
    }

    private func noteSemaphoreMiss() {
        recentSemaphoreMisses = min(recentSemaphoreMisses + 1, 8)
        publishBehindFlagIfChanged()
    }

    /// - Parameter contentFrame: true when this present uploaded a new UDP
    ///   frame. Live mode presents once per content frame; only those count
    ///   toward the overlay's present FPS so it stays near ~50 Hz when healthy.
    private func noteSuccessfulPresent(contentFrame: Bool) {
        if recentSemaphoreMisses > 0 {
            recentSemaphoreMisses -= 1
        }
        let now = DispatchTime.now()
        // lastFrameSubmission is written on the UDP receive thread under
        // textureLock — never read the Optional unlocked (torn tag/value
        // can invent a “future” timestamp and trap on UInt64 subtract).
        textureLock.lock()
        let lastSubmission = lastFrameSubmission
        textureLock.unlock()
        if let last = lastSuccessfulPresentTime {
            let gap = Self.secondsElapsed(since: last, now: now)
            let recentlyFed = lastSubmission.map {
                Self.secondsElapsed(since: $0, now: now) < 0.15
            } ?? false
            // Live presents follow panel vsync (~16.7 ms on 60 Hz).
            if recentlyFed, gap > (1.0 / 45.0), gap < 0.25 {
                slowPresentStreak = min(slowPresentStreak + 1, 10)
                if Self.debug {
                    NSLog("[render] present gap %.1f ms", gap * 1000)
                }
            } else if gap <= (1.0 / 55.0) {
                slowPresentStreak = max(0, slowPresentStreak - 2)
            }
        }
        lastSuccessfulPresentTime = now
        publishBehindFlagIfChanged()
        if contentFrame {
            presentCount += 1
        }
        let elapsed = Self.secondsElapsed(since: lastPresentStatsTime, now: now)
        guard elapsed >= 1.0 else { return }
        let fps = Double(presentCount) / elapsed
        presentCount = 0
        lastPresentStatsTime = now
        lastReportedPresentFPS = fps
        // Defer off the draw path so SwiftUI overlay updates cannot stall
        // the next 50 Hz present tick.
        let reportFPS = fps
        let behind = isGPUBehind
        DispatchQueue.main.async { [weak self] in
            self?.onLoadStats?(reportFPS, behind)
        }
    }

    private func publishBehindFlagIfChanged() {
        let behind = recentSemaphoreMisses >= 2 || slowPresentStreak >= 3
        guard behind != isGPUBehind else { return }
        isGPUBehind = behind
        let reportFPS = lastReportedPresentFPS
        DispatchQueue.main.async { [weak self] in
            self?.onLoadStats?(reportFPS, behind)
        }
    }

    func draw(in view: MTKView) {
        cachedDrawableSize = view.drawableSize
        if !isLivePresentMode {
            leaveLivePresentModeIfIdle()
        }

        guard inFlightSemaphore.wait(timeout: .now()) == .success else {
            noteSemaphoreMiss()
            scheduleDeferredRedraw()
            return
        }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        textureLock.lock()
        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)
        let resetHistory = resetHistoryOnNextFrame
        if !frames.isEmpty { resetHistoryOnNextFrame = false }
        let palette = palettePendingBytes
        palettePendingBytes = nil
        textureLock.unlock()

        // Cap to one upload per draw. Draining every pending frame while the
        // previous command buffer still reads historyTexture races the CPU
        // replace under CRT back-pressure. Keep the latest frame; intermediate
        // motion-blend steps are dropped when the GPU is behind.
        var uploadedContentFrame = false
        if let palette,
           let replacement = Self.makePaletteTexture(
                device: device, bytes: palette) {
            paletteTexture = replacement
        }
        // CPU→index replace + GPU blit into history before the render pass.
        if let frame = frames.last {
            if frames.count > 1 {
                textureLock.lock()
                droppedSourceFrameCount += frames.count - 1
                textureLock.unlock()
            }
            uploadFrameData(
                frame,
                resetHistory: resetHistory || frames.count > 1,
                commandBuffer: commandBuffer)
            uploadedContentFrame = true
            if Self.debug {
                dbgDrawn += 1
                if frames.count > 1 {
                    NSLog("[render] dropped %d intermediate frame(s)",
                          frames.count - 1)
                }
            }
        }

        // Allocate encoder-pool storage only for an actual source frame.
        // Display-link refreshes still present normally but must not consume a
        // pixel buffer or duplicate a frame in the movie.
        let recordingRequest = uploadedContentFrame ? filteredRecordingRequest : nil
        let recordingTarget = recordingRequest.flatMap(makeFilteredRecordingTarget)
        let encodedFrame: Bool
        if let recordingTarget {
            guard encodeFilteredRecordingFrame(
                commandBuffer: commandBuffer, target: recordingTarget),
                  encodeFilteredRecordingPresentation(
                    commandBuffer: commandBuffer,
                    descriptor: descriptor,
                    target: recordingTarget,
                    drawableSize: view.drawableSize) else {
                commandBuffer.commit()
                return
            }
            encodedFrame = true
        } else {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor) else {
                // Blits may already be encoded — commit so the completion
                // handler releases the in-flight slot.
                commandBuffer.commit()
                return
            }
            _ = encodeFrame(
                encoder: encoder,
                drawableSize: view.drawableSize,
                frame: nil,
                resetHistory: false,
                palette: nil)
            encoder.endEncoding()
            encodedFrame = true
        }
        guard encodedFrame else {
            // Blits may already be encoded — commit so the completion
            // handler releases the in-flight slot.
            commandBuffer.commit()
            return
        }

        textureLock.lock()
        let shotCompletion = pendingScreenshotCompletion
        pendingScreenshotCompletion = nil
        textureLock.unlock()
        if let shotCompletion {
            encodeScreenshotPass(
                commandBuffer: commandBuffer,
                pipeline: pipelineForCurrentFilter(),
                uniforms: makeUniforms(drawableSize: view.drawableSize),
                indexTexture: indexTextures[currentTextureIndex],
                drawableSize: view.drawableSize,
                completion: shotCompletion)
        }
        // The target is an adaptor-pool buffer. Retain it through GPU
        // completion, then append it at the stream rate.
        if let recordingRequest, let recordingTarget {
            commandBuffer.addCompletedHandler { _ in
                recordingRequest.consume(recordingTarget.pixelBuffer)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        noteSuccessfulPresent(contentFrame: uploadedContentFrame)
    }

    deinit {
        animationTimer?.invalidate()
        livePresentIdleTimer?.invalidate()
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
        // A C64 on a real TV displays at 4:3 — stream pixels are not square
        // (384×272 PAL or 384×240 NTSC), so scaling targets the display
        // aspect. Integer mode falls back to Fit when the largest
        // whole-pixel scale would leave most of the window empty.
        VideoScaling.scaleFactors(
            mode: scalingMode,
            drawableSize: drawableSize,
            frameHeight: Float(sourceFrameHeight))
    }
}

/// Standard C64 palettes (RGBA).
enum C64Palette {
    private static func rgba(_ values: [(UInt8, UInt8, UInt8)]) -> [SIMD4<UInt8>] {
        values.map { .init($0.0, $0.1, $0.2, 0xFF) }
    }

    static let peptoPALColors: [C64RGBAColor] = [
        .init(0x00, 0x00, 0x00), .init(0xFF, 0xFF, 0xFF),
        .init(0x68, 0x37, 0x2B), .init(0x70, 0xA4, 0xB2),
        .init(0x6F, 0x3D, 0x86), .init(0x58, 0x8D, 0x43),
        .init(0x35, 0x28, 0x79), .init(0xB8, 0xC7, 0x6F),
        .init(0x6F, 0x4F, 0x25), .init(0x43, 0x39, 0x00),
        .init(0x9A, 0x67, 0x59), .init(0x44, 0x44, 0x44),
        .init(0x6C, 0x6C, 0x6C), .init(0x9A, 0xD2, 0x84),
        .init(0x6C, 0x5E, 0xB5), .init(0x95, 0x95, 0x95),
    ]

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

    // Curated catalog values. PAL VIC-II revisions intentionally vary in
    // saturation/luma; these are colorimetry presets, not post-processing.
    static let peptoNTSC = rgba([
        (0,0,0),(255,255,255),(129,51,56),(117,206,200),
        (142,60,151),(86,172,77),(46,44,155),(237,241,113),
        (142,80,41),(85,56,0),(196,108,113),(74,74,74),
        (123,123,123),(169,255,159),(112,109,235),(178,178,178)
    ])
    static let deekay = rgba([
        (0,0,0),(255,255,255),(136,57,50),(112,164,178),
        (124,55,139),(88,141,67),(53,40,121),(184,199,111),
        (111,79,37),(67,57,0),(154,103,89),(68,68,68),
        (108,108,108),(154,210,132),(108,94,181),(149,149,149)
    ])
    static let communityColors = rgba([
        (0,0,0),(255,255,255),(137,64,54),(112,190,190),
        (132,57,145),(88,170,74),(57,53,155),(224,224,108),
        (145,91,38),(85,57,0),(190,111,95),(64,64,64),
        (128,128,128),(151,224,135),(114,101,213),(190,190,190)
    ])
    static let ptoing = rgba([
        (0,0,0),(255,255,255),(136,57,50),(112,164,178),
        (124,55,139),(88,141,67),(53,40,121),(184,199,111),
        (111,79,37),(67,57,0),(154,103,89),(68,68,68),
        (108,108,108),(154,210,132),(108,94,181),(149,149,149)
    ])
    static let palVICII6569R1 = rgba([
        (0,0,0),(255,255,255),(111,45,39),(91,166,172),
        (106,45,117),(72,139,62),(42,35,114),(190,194,91),
        (116,72,30),(70,48,0),(157,91,79),(48,48,48),
        (91,91,91),(131,203,115),(93,82,166),(140,140,140)
    ])
    static let palVICII6569R3 = rgba([
        (0,0,0),(255,255,255),(124,50,43),(100,181,187),
        (117,50,130),(80,151,68),(47,39,132),(204,208,98),
        (125,78,33),(76,52,0),(174,100,86),(55,55,55),
        (102,102,102),(145,217,126),(101,89,182),(153,153,153)
    ])
    static let palVICII6569R4 = rgba([
        (0,0,0),(255,255,255),(112,47,41),(95,173,180),
        (109,46,122),(75,145,65),(44,37,123),(195,201,95),
        (119,74,31),(72,49,0),(163,95,82),(52,52,52),
        (97,97,97),(138,209,121),(96,85,174),(146,146,146)
    ])
    static let palVICII6569R5 = rgba([
        (0,0,0),(255,255,255),(116,49,42),(98,177,184),
        (113,48,126),(78,148,66),(46,38,127),(200,204,97),
        (122,76,32),(74,51,0),(168,97,84),(54,54,54),
        (100,100,100),(142,213,123),(99,87,178),(150,150,150)
    ])
    static let palVICII8565R2 = rgba([
        (0,0,0),(255,255,255),(128,52,46),(104,187,194),
        (122,51,135),(82,157,70),(49,41,138),(211,214,103),
        (130,81,34),(79,54,0),(180,104,90),(58,58,58),
        (106,106,106),(151,223,132),(105,92,188),(159,159,159)
    ])

    static func palette(for choice: PaletteChoice) -> [SIMD4<UInt8>] {
        switch choice {
        case .peptoPAL: return pepto
        case .peptoNTSC: return peptoNTSC
        case .colodore: return colodore
        case .vice: return vice
        case .deekay: return deekay
        case .communityColors: return communityColors
        case .ptoing: return ptoing
        case .palVICII6569R1: return palVICII6569R1
        case .palVICII6569R3: return palVICII6569R3
        case .palVICII6569R4: return palVICII6569R4
        case .palVICII6569R5: return palVICII6569R5
        case .palVICII8565R2: return palVICII8565R2
        case .custom: return pepto
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
