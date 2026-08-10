import Foundation
import Metal
import MetalKit
import simd

/// Compact encoding uploaded to the renderer's 256×256 RG8 texture.
/// R is the raw byte value; G uses bit 0 for "observed" and bit 1 for write.
enum MemoryMap3DInstanceEncoding {
    static func flags(accessed: Bool, wasRead: Bool) -> UInt8 {
        guard accessed else { return 0 }
        return wasRead ? 0x01 : 0x03
    }

    static func normalizedHeight(for byte: UInt8) -> Float {
        Float(byte) / 255
    }
}

struct MemoryMap3DInspection: Equatable {
    let address: UInt16
    let value: UInt8
    let wasRead: Bool
    let region: String
}

struct MemoryMap3DOptions: Equatable {
    var adaptiveLOD = true
    var hoverInspection = true
    var regionOverlays = true
    var activityPulse = true
}

/// Orbit camera kept independent from SwiftUI so drag/magnify events can
/// redraw the Metal view directly without publishing through the window.
struct MemoryMap3DCamera: Equatable {
    static let defaultYaw: Float = .pi / 4
    static let defaultPitch: Float = 0.6154797 // canonical isometric angle
    static let defaultDistance: Float = 1.75
    static let minimumPitch: Float = 0.12
    static let maximumPitch: Float = 1.45
    static let minimumDistance: Float = 0.85
    static let maximumDistance: Float = 4.0

    var yaw = Self.defaultYaw
    var pitch = Self.defaultPitch
    var distance = Self.defaultDistance

    mutating func rotate(deltaX: Float, deltaY: Float) {
        yaw += deltaX * 0.008
        pitch = min(
            Self.maximumPitch,
            max(Self.minimumPitch, pitch - deltaY * 0.008))
    }

    mutating func zoom(scrollDelta: Float) {
        distance *= exp(scrollDelta * 0.018)
        distance = min(
            Self.maximumDistance,
            max(Self.minimumDistance, distance))
    }

    mutating func magnify(_ amount: Float) {
        distance /= exp(amount * 2.0)
        distance = min(
            Self.maximumDistance,
            max(Self.minimumDistance, distance))
    }

    mutating func reset() {
        self = MemoryMap3DCamera()
    }

    func viewProjection(aspect: Float) -> simd_float4x4 {
        let horizontal = cos(pitch)
        let eye = SIMD3<Float>(
            sin(yaw) * horizontal,
            sin(pitch),
            cos(yaw) * horizontal) * distance
        let target = SIMD3<Float>(0, 0.12, 0)
        let view = simd_float4x4.lookAt(
            eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
        let projection = simd_float4x4.perspective(
            verticalFOV: .pi / 4,
            aspect: max(0.1, aspect),
            near: 0.05,
            far: 10)
        return projection * view
    }
}

/// Draws all 65,536 byte positions as GPU-instanced bars. Bar geometry is
/// generated entirely in the vertex shader from vertex/instance IDs; the CPU
/// repacks instance buffers only when the heatmap generation or LOD changes.
/// Activity pulse decays in the shader from per-instance access timestamps so
/// the 20 Hz timer can redraw without scanning 64K addresses every tick.
final class MemoryMap3DRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var viewProjection: simd_float4x4
        var maximumHeight: Float
        var cellSize: Float
        /// 0 = C64 CPU/VIC regions, 1 = 1541 regions.
        var sourceMode: Float
        var regionOverlays: Float
        /// Seconds since `timeBase` — used with per-instance `accessedAt`.
        var currentTime: Float
        /// 1 when activity pulse is enabled.
        var activityPulseEnabled: Float
    }

    struct InstanceData {
        /// Low 16 bits = X/low-byte origin, high 16 bits = Z/page origin.
        var coordinate: UInt32
        /// Low byte = value; next byte = flags from
        /// `MemoryMap3DInstanceEncoding`; third byte = LOD block span.
        var packedValueFlagsAndSpan: UInt32
        /// Access time relative to renderer `timeBase`, or -1 if unused.
        var accessedAt: Float
        var padding: UInt32 = 0
    }

    static func lodBlockSize(for distance: Float) -> Int {
        if distance < 1.35 { return 1 }
        if distance < 2.15 { return 2 }
        if distance < 3.05 { return 4 }
        return 8
    }

    /// Decision for one timer tick — kept pure for unit tests.
    enum TickAction: Equatable {
        /// Nothing to do this tick.
        case skip
        /// Re-present existing instances (activity pulse / camera) — no snapshot.
        case redrawOnly
        /// Copy heatmap + rebuild instance buffers.
        case rebuild
    }

    /// - Parameters:
    ///   - stableTickParity: increments on every timer fire while generation
    ///     is unchanged; used to present activity-only frames at half rate
    ///     (10 Hz from a 20 Hz timer).
    static func tickAction(
        generation: UInt64,
        lastGeneration: UInt64?,
        blockSize: Int,
        lastLOD: Int,
        activityPulse: Bool,
        stableTickParity: Int,
        videoGPUBehind: Bool
    ) -> TickAction {
        if videoGPUBehind { return .skip }
        let dataChanged = lastGeneration != generation || lastLOD != blockSize
        if dataChanged { return .rebuild }
        guard activityPulse else { return .skip }
        // Half-rate presents while only the shader clock advances.
        return stableTickParity.isMultiple(of: 2) ? .redrawOnly : .skip
    }

    /// Fills `destination` from a heatmap snapshot. Pure CPU work — safe to
    /// run off the main thread so the live CRT present path is not blocked.
    static func fillInstances(
        values: [UInt8],
        accessTimes: [Double],
        directions: [Bool],
        blockSize: Int,
        timeBase: Double,
        destination: UnsafeMutablePointer<InstanceData>
    ) -> Int {
        var instanceCount = 0
        for blockZ in stride(from: 0, to: 256, by: blockSize) {
            for blockX in stride(from: 0, to: 256, by: blockSize) {
                var valueTotal = 0
                var observedCount = 0
                var latestAccess = 0.0
                var latestWasRead = true
                for z in blockZ..<(blockZ + blockSize) {
                    for x in blockX..<(blockX + blockSize) {
                        let address = z * 256 + x
                        let access = accessTimes[address]
                        guard access > 0 else { continue }
                        valueTotal += Int(values[address])
                        observedCount += 1
                        if access >= latestAccess {
                            latestAccess = access
                            latestWasRead = directions[address]
                        }
                    }
                }

                guard observedCount > 0 else { continue }
                let value = UInt8(valueTotal / observedCount)
                // Zero-height blocks are visually identical to no geometry.
                guard value > 0 else { continue }
                let flags = MemoryMap3DInstanceEncoding.flags(
                    accessed: true,
                    wasRead: latestWasRead)
                let accessedAt: Float = latestAccess > 0
                    ? Float(latestAccess - timeBase)
                    : -1
                destination[instanceCount] = InstanceData(
                    coordinate:
                        UInt32(blockX) | (UInt32(blockZ) << 16),
                    packedValueFlagsAndSpan:
                        UInt32(value)
                        | (UInt32(flags) << 8)
                        | (UInt32(blockSize) << 16),
                    accessedAt: accessedAt)
                instanceCount += 1
            }
        }
        return instanceCount
    }

    static func activityIntensity(
        accessedAt: Double,
        now: Double
    ) -> Float {
        guard accessedAt > 0 else { return 0 }
        let linear = max(0, 1 - (now - accessedAt) / 0.35)
        return Float(linear * linear)
    }

    static func regionName(
        for address: UInt16,
        source: DebugStreamSource
    ) -> String {
        let value = Int(address)
        switch source {
        case .drive1541:
            switch value {
            case 0x0000...0x00FF: return "1541 zero page"
            case 0x0100...0x01FF: return "1541 stack"
            case 0x0200...0x07FF: return "1541 RAM/buffers"
            case 0x1800...0x1BFF: return "1541 VIA1 (IEC)"
            case 0x1C00...0x1FFF: return "1541 VIA2 (motor)"
            case 0xC000...0xFFFF: return "1541 DOS ROM"
            default: return "1541 address space"
            }
        case .cpu6510, .vic:
            switch value {
            case 0x0000...0x00FF: return "Zero page"
            case 0x0100...0x01FF: return "Stack"
            case 0x0200...0x03FF: return "KERNAL workspace"
            case 0x0400...0x07FF: return "Screen RAM"
            case 0x0800...0x9FFF: return "RAM"
            case 0xA000...0xBFFF: return "BASIC ROM / RAM"
            case 0xC000...0xCFFF: return "High RAM"
            case 0xD000...0xD3FF: return "VIC-II / Character ROM"
            case 0xD400...0xD7FF: return "SID / Character ROM"
            case 0xD800...0xDBFF: return "Color RAM / Character ROM"
            case 0xDC00...0xDCFF: return "CIA1 / Character ROM"
            case 0xDD00...0xDDFF: return "CIA2 / Character ROM"
            case 0xDE00...0xDEFF: return "I/O 1 / Character ROM"
            case 0xDF00...0xDFFF: return "I/O 2 / Character ROM"
            case 0xE000...0xFFFF: return "KERNAL ROM / RAM"
            default: return "RAM"
            }
        }
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewProjection;
        float maximumHeight;
        float cellSize;
        float sourceMode;
        float regionOverlays;
        float currentTime;
        float activityPulseEnabled;
    };

    struct BarVertexOut {
        float4 position [[position]];
        float3 normal;
        float3 color;
    };

    struct InstanceData {
        uint coordinate;
        uint packedValueFlagsAndSpan;
        float accessedAt;
        uint padding;
    };

    struct BaseVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    constant float3 barPositions[30] = {
        // Top
        {-0.5, 1, -0.5}, { 0.5, 1, -0.5}, { 0.5, 1,  0.5},
        {-0.5, 1, -0.5}, { 0.5, 1,  0.5}, {-0.5, 1,  0.5},
        // Front
        {-0.5, 0,  0.5}, { 0.5, 0,  0.5}, { 0.5, 1,  0.5},
        {-0.5, 0,  0.5}, { 0.5, 1,  0.5}, {-0.5, 1,  0.5},
        // Back
        { 0.5, 0, -0.5}, {-0.5, 0, -0.5}, {-0.5, 1, -0.5},
        { 0.5, 0, -0.5}, {-0.5, 1, -0.5}, { 0.5, 1, -0.5},
        // Left
        {-0.5, 0, -0.5}, {-0.5, 0,  0.5}, {-0.5, 1,  0.5},
        {-0.5, 0, -0.5}, {-0.5, 1,  0.5}, {-0.5, 1, -0.5},
        // Right
        { 0.5, 0,  0.5}, { 0.5, 0, -0.5}, { 0.5, 1, -0.5},
        { 0.5, 0,  0.5}, { 0.5, 1, -0.5}, { 0.5, 1,  0.5}
    };

    constant float3 barNormals[30] = {
        {0,1,0},{0,1,0},{0,1,0},{0,1,0},{0,1,0},{0,1,0},
        {0,0,1},{0,0,1},{0,0,1},{0,0,1},{0,0,1},{0,0,1},
        {0,0,-1},{0,0,-1},{0,0,-1},{0,0,-1},{0,0,-1},{0,0,-1},
        {-1,0,0},{-1,0,0},{-1,0,0},{-1,0,0},{-1,0,0},{-1,0,0},
        {1,0,0},{1,0,0},{1,0,0},{1,0,0},{1,0,0},{1,0,0}
    };

    vertex BarVertexOut memoryBarVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device InstanceData *instances [[buffer(1)]],
        constant Uniforms &uniforms [[buffer(0)]]
    ) {
        InstanceData instance = instances[instanceID];
        uint x = instance.coordinate & 65535;
        uint z = instance.coordinate >> 16;
        uint valueByte = instance.packedValueFlagsAndSpan & 255;
        uint flags = (instance.packedValueFlagsAndSpan >> 8) & 255;
        uint span = (instance.packedValueFlagsAndSpan >> 16) & 255;
        float value = float(valueByte) / 255.0;
        bool isWrite = (flags & 2) != 0;
        float height = value * uniforms.maximumHeight;

        float3 local = barPositions[vertexID];
        float barWidth = uniforms.cellSize * float(span) * 0.78;
        float3 world = float3(
            (float(x) + float(span) * 0.5) * uniforms.cellSize - 0.5
                + local.x * barWidth,
            local.y * height,
            (float(z) + float(span) * 0.5) * uniforms.cellSize - 0.5
                + local.z * barWidth);

        float activity = 0.0;
        if (uniforms.activityPulseEnabled > 0.5 && instance.accessedAt >= 0.0) {
            float linear = clamp(
                1.0 - (uniforms.currentTime - instance.accessedAt) / 0.35,
                0.0,
                1.0);
            activity = linear * linear;
        }

        BarVertexOut out;
        out.position = uniforms.viewProjection * float4(world, 1);
        out.normal = barNormals[vertexID];
        float3 baseColor = isWrite ? float3(1.0, 0.42, 0.055)
                                   : float3(0.08, 1.0, 0.26);
        out.color = mix(
            baseColor,
            float3(1.0),
            clamp(activity, 0.0, 1.0) * 0.58);
        return out;
    }

    fragment float4 memoryBarFragment(BarVertexOut in [[stage_in]]) {
        float3 lightDirection = normalize(float3(-0.45, 0.9, -0.35));
        float lighting = 0.30 + 0.70 * max(dot(in.normal, lightDirection), 0.0);
        return float4(in.color * lighting, 1);
    }

    constant float3 basePositions[6] = {
        {-0.515, -0.002, -0.515}, { 0.515, -0.002, -0.515},
        { 0.515, -0.002,  0.515}, {-0.515, -0.002, -0.515},
        { 0.515, -0.002,  0.515}, {-0.515, -0.002,  0.515}
    };
    constant float2 baseUVs[6] = {
        {0,0},{1,0},{1,1},{0,0},{1,1},{0,1}
    };
    constant float c64RegionBoundaries[15] = {
        1, 2, 4, 8, 160, 192, 208, 212,
        216, 220, 221, 222, 223, 224, 256
    };
    constant float driveRegionBoundaries[6] = {
        1, 2, 8, 24, 28, 192
    };

    vertex BaseVertexOut memoryBaseVertex(
        uint vertexID [[vertex_id]],
        constant Uniforms &uniforms [[buffer(0)]]
    ) {
        BaseVertexOut out;
        out.position = uniforms.viewProjection * float4(basePositions[vertexID], 1);
        out.uv = baseUVs[vertexID];
        return out;
    }

    fragment float4 memoryBaseFragment(
        BaseVertexOut in [[stage_in]],
        constant Uniforms &uniforms [[buffer(0)]]
    ) {
        float2 coordinate = in.uv * 256.0;
        float2 gridDistance = abs(fract(coordinate - 0.5) - 0.5)
                            / max(fwidth(coordinate), float2(0.001));
        float gridLine = 1.0 - min(min(gridDistance.x, gridDistance.y), 1.0);
        float page = clamp(floor(coordinate.y), 0.0, 255.0);
        float3 regionTint = float3(0.0);
        if (uniforms.regionOverlays > 0.5 &&
            in.uv.x >= 0.0 && in.uv.x <= 1.0) {
            if (in.position.w > 0.0) {
                // ROM areas: cool blue; I/O areas: restrained purple.
                if ((uniforms.sourceMode < 0.5 &&
                     ((page >= 160.0 && page < 192.0) || page >= 224.0)) ||
                    (uniforms.sourceMode >= 0.5 && page >= 192.0)) {
                    regionTint = float3(0.012, 0.024, 0.055);
                } else if ((uniforms.sourceMode < 0.5 &&
                            page >= 208.0 && page < 224.0) ||
                           (uniforms.sourceMode >= 0.5 &&
                            page >= 24.0 && page < 32.0)) {
                    regionTint = float3(0.035, 0.012, 0.050);
                }
            }
        }

        float boundary = 0.0;
        if (uniforms.regionOverlays < 0.5) {
            boundary = 0.0;
        } else if (uniforms.sourceMode < 0.5) {
            for (uint i = 0; i < 15; ++i) {
                boundary = max(
                    boundary,
                    1.0 - smoothstep(
                        0.0,
                        max(fwidth(coordinate.y) * 1.2, 0.25),
                        abs(coordinate.y - c64RegionBoundaries[i])));
            }
        } else {
            for (uint i = 0; i < 6; ++i) {
                boundary = max(
                    boundary,
                    1.0 - smoothstep(
                        0.0,
                        max(fwidth(coordinate.y) * 1.2, 0.25),
                        abs(coordinate.y - driveRegionBoundaries[i])));
            }
        }

        float brightness = 0.012 + gridLine * 0.060 + boundary * 0.10;
        return float4(float3(brightness) + regionTint, 1);
    }
    """

    private weak var view: MTKView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let barPipeline: MTLRenderPipelineState
    private let basePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var instanceBuffers: [MTLBuffer]
    private var currentBufferIndex = 0
    private var currentInstanceCount = 0
    private var bufferInFlight = [Bool](repeating: false, count: 3)
    private let bufferLock = NSLock()
    private var timer: Timer?
    private var drawPending = false
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private var lastDataGeneration: UInt64?
    private var lastLOD = 0
    /// Epoch for packing access timestamps as Float seconds (avoids losing
    /// sub-second precision that absolute CFAbsoluteTime has in Float).
    private let timeBase = CFAbsoluteTimeGetCurrent()
    private var deferredRedrawPending = false
    /// Counts timer firings while heatmap generation is unchanged so
    /// activity-only presents can run at 10 Hz on a 20 Hz timer.
    private var stableTickParity = 0
    /// Buffer index currently being filled on a background queue, if any.
    private var buildingBufferIndex: Int?
    /// When true, this tick yields to the session's CRT video path.
    var videoGPUBehind: () -> Bool = { false }

    var heatmap: MemoryHeatmap?
    var source: DebugStreamSource = .cpu6510
    var options = MemoryMap3DOptions() {
        didSet {
            guard options != oldValue else { return }
            refreshSnapshot()
        }
    }
    private(set) var camera = MemoryMap3DCamera()

    init?(mtkView: MTKView, heatmap: MemoryHeatmap) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.heatmap = heatmap
        self.view = mtkView

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        do {
            let library = try device.makeLibrary(
                source: Self.shaderSource, options: nil)
            let barDescriptor = MTLRenderPipelineDescriptor()
            barDescriptor.vertexFunction = library.makeFunction(
                name: "memoryBarVertex")
            barDescriptor.fragmentFunction = library.makeFunction(
                name: "memoryBarFragment")
            barDescriptor.colorAttachments[0].pixelFormat =
                mtkView.colorPixelFormat
            barDescriptor.depthAttachmentPixelFormat =
                mtkView.depthStencilPixelFormat
            barPipeline = try device.makeRenderPipelineState(
                descriptor: barDescriptor)

            let baseDescriptor = MTLRenderPipelineDescriptor()
            baseDescriptor.vertexFunction = library.makeFunction(
                name: "memoryBaseVertex")
            baseDescriptor.fragmentFunction = library.makeFunction(
                name: "memoryBaseFragment")
            baseDescriptor.colorAttachments[0].pixelFormat =
                mtkView.colorPixelFormat
            baseDescriptor.depthAttachmentPixelFormat =
                mtkView.depthStencilPixelFormat
            basePipeline = try device.makeRenderPipelineState(
                descriptor: baseDescriptor)
        } catch {
            assertionFailure("3D memory-map shader compilation failed: \(error)")
            return nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(
            descriptor: depthDescriptor)
        else { return nil }
        self.depthState = depthState

        let bufferLength =
            MemoryLayout<InstanceData>.stride * MemoryHeatmap.addressSpace
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let buffer = device.makeBuffer(
                length: bufferLength,
                options: .storageModeShared)
            else { return nil }
            buffers.append(buffer)
        }
        instanceBuffers = buffers

        super.init()
        mtkView.delegate = self
        refreshSnapshot()
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        view?.delegate = nil
    }

    func rotate(deltaX: Float, deltaY: Float) {
        camera.rotate(deltaX: deltaX, deltaY: deltaY)
        // Do not draw for every mouse event. The 20 Hz refresh timer below
        // presents the latest accumulated camera state, preventing drag
        // events from flooding the GPU and starving the main C64 renderer.
    }

    func zoom(scrollDelta: Float) {
        camera.zoom(scrollDelta: scrollDelta)
    }

    func magnify(_ amount: Float) {
        camera.magnify(amount)
    }

    func resetCamera() {
        camera.reset()
        requestDraw()
    }

    func inspect(
        point: CGPoint,
        in view: MTKView
    ) -> MemoryMap3DInspection? {
        guard options.hoverInspection,
              let heatmap,
              view.bounds.width > 0,
              view.bounds.height > 0
        else { return nil }

        let aspect = Float(
            view.drawableSize.width / max(view.drawableSize.height, 1))
        let inverse = simd_inverse(
            camera.viewProjection(aspect: aspect))
        let ndcX = Float(point.x / view.bounds.width * 2 - 1)
        let ndcY = Float(point.y / view.bounds.height * 2 - 1)

        func unproject(z: Float) -> SIMD3<Float> {
            var world = inverse * SIMD4<Float>(ndcX, ndcY, z, 1)
            world /= world.w
            return SIMD3<Float>(world.x, world.y, world.z)
        }

        let nearPoint = unproject(z: 0)
        let farPoint = unproject(z: 1)
        let direction = farPoint - nearPoint
        guard abs(direction.y) > 0.00001 else { return nil }
        let distanceToPlane = -nearPoint.y / direction.y
        guard distanceToPlane >= 0 else { return nil }
        let hit = nearPoint + direction * distanceToPlane
        guard hit.x >= -0.5, hit.x < 0.5,
              hit.z >= -0.5, hit.z < 0.5
        else { return nil }

        let x = min(255, max(0, Int((hit.x + 0.5) * 256)))
        let z = min(255, max(0, Int((hit.z + 0.5) * 256)))
        let address = UInt16((z << 8) | x)
        let index = Int(address)
        guard let state = heatmap.state(at: index),
              state.lastAccess > 0 else { return nil }
        return MemoryMap3DInspection(
            address: address,
            value: state.lastValue,
            wasRead: state.lastAccessWasRead,
            region: Self.regionName(for: address, source: source))
    }

    func refreshSnapshot() {
        guard let heatmap else { return }
        guard view?.window == nil
                || view?.window?.occlusionState.contains(.visible) == true
        else { return }
        let blockSize = options.adaptiveLOD
            ? Self.lodBlockSize(for: camera.distance)
            : 1
        let generation = heatmap.currentGeneration()
        let dataChanged = lastDataGeneration != generation || lastLOD != blockSize
        if dataChanged {
            stableTickParity = 0
        } else {
            stableTickParity &+= 1
        }
        switch Self.tickAction(
            generation: generation,
            lastGeneration: lastDataGeneration,
            blockSize: blockSize,
            lastLOD: lastLOD,
            activityPulse: options.activityPulse,
            stableTickParity: stableTickParity,
            videoGPUBehind: videoGPUBehind()
        ) {
        case .skip:
            return
        case .redrawOnly:
            requestDraw()
            return
        case .rebuild:
            break
        }

        // Snapshot + 64K LOD pack are expensive; do them off the main run
        // loop so CRT `draw(in:)` is not delayed by secondary viz work.
        guard buildingBufferIndex == nil else { return }
        bufferLock.lock()
        let busy = Set(
            bufferInFlight.enumerated().compactMap { $0.element ? $0.offset : nil }
            + [currentBufferIndex])
        guard let nextBufferIndex = (0..<instanceBuffers.count).first(
            where: { !busy.contains($0) })
        else {
            bufferLock.unlock()
            scheduleDeferredRedraw()
            return
        }
        bufferLock.unlock()

        buildingBufferIndex = nextBufferIndex
        let buffer = instanceBuffers[nextBufferIndex]
        let timeBase = self.timeBase
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = heatmap.renderSnapshot()
            let destination = buffer.contents().bindMemory(
                to: InstanceData.self,
                capacity: MemoryHeatmap.addressSpace)
            let instanceCount = Self.fillInstances(
                values: snapshot.lastValue,
                accessTimes: snapshot.lastAccess,
                directions: snapshot.lastAccessWasRead,
                blockSize: blockSize,
                timeBase: timeBase,
                destination: destination)
            DispatchQueue.main.async {
                guard let self else { return }
                self.buildingBufferIndex = nil
                // Window may have closed while the pack was in flight.
                guard self.view != nil else { return }
                self.currentBufferIndex = nextBufferIndex
                self.currentInstanceCount = instanceCount
                self.lastDataGeneration = snapshot.generation
                self.lastLOD = blockSize
                self.requestDraw()
            }
        }
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) {
            [weak self] _ in
            self?.refreshSnapshot()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func requestDraw() {
        guard !drawPending, let view else { return }
        drawPending = true
        view.setNeedsDisplay(view.bounds)
    }

    private func scheduleDeferredRedraw() {
        guard !deferredRedrawPending else { return }
        deferredRedrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredRedrawPending = false
            self.requestDraw()
        }
    }

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {
        requestDraw()
    }

    func draw(in view: MTKView) {
        drawPending = false
        // Prefer the live CRT stream when its display path is under pressure.
        guard !videoGPUBehind() else { return }
        guard inFlightSemaphore.wait(timeout: .now()) == .success else {
            scheduleDeferredRedraw()
            return
        }
        guard view.drawableSize.width > 0,
              view.drawableSize.height > 0,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor)
        else {
            inFlightSemaphore.signal()
            return
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        var uniforms = Uniforms(
            viewProjection: camera.viewProjection(
                aspect: Float(view.drawableSize.width /
                              view.drawableSize.height)),
            maximumHeight: 0.46,
            cellSize: 1.0 / Float(MemoryMapView.side),
            sourceMode: source == .drive1541 ? 1 : 0,
            regionOverlays: options.regionOverlays ? 1 : 0,
            currentTime: Float(CFAbsoluteTimeGetCurrent() - timeBase),
            activityPulseEnabled: options.activityPulse ? 1 : 0)

        encoder.setDepthStencilState(depthState)
        encoder.setRenderPipelineState(basePipeline)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<Uniforms>.stride,
            index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<Uniforms>.stride,
            index: 0)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6)

        encoder.setRenderPipelineState(barPipeline)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<Uniforms>.stride,
            index: 0)
        if currentInstanceCount > 0 {
            bufferLock.lock()
            bufferInFlight[currentBufferIndex] = true
            bufferLock.unlock()
            encoder.setVertexBuffer(
                instanceBuffers[currentBufferIndex],
                offset: 0,
                index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 30,
                instanceCount: currentInstanceCount)
        }
        encoder.endEncoding()
        let submittedBufferIndex = currentBufferIndex
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.bufferLock.lock()
            self.bufferInFlight[submittedBufferIndex] = false
            self.bufferLock.unlock()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private extension simd_float4x4 {
    static func perspective(
        verticalFOV: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let y = 1 / tan(verticalFOV * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }

    static func lookAt(
        eye: SIMD3<Float>,
        target: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(
                -simd_dot(x, eye),
                -simd_dot(y, eye),
                -simd_dot(z, eye),
                1)
        ))
    }
}
