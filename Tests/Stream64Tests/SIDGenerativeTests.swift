import XCTest
import MetalKit
import AppKit
@testable import Stream64

final class SIDGenerativeTests: XCTestCase {
    private let modes = SIDVisualizationMode.allCases.filter(\.isGenerative)

    func testLogoLoadsAndKAOSRotationCoversEveryScene() throws {
        let logo = try XCTUnwrap(SIDLogoAsset.image(for: .c64Ultimate))
        XCTAssertGreaterThan(logo.size.width, 0)
        XCTAssertGreaterThan(logo.size.height, 0)
        let count = SIDKAOSView.KAOSScene.allCases.count
        for phrase in 0..<8 {
            let visited = Set((0..<count).map {
                SIDKAOSView.shuffledSceneIndex(step: $0, phrase: phrase, count: count)
            })
            XCTAssertEqual(visited.count, count)
            XCTAssertTrue(visited.contains(SIDKAOSView.KAOSScene.ultimateLogo.rawValue))
        }
    }

    func testHardwareLogoSelectionAndSwitching() throws {
        for product in ["Ultimate 64", "Ultimate 64 Elite", "Ultimate 64-II", "U64", "u64 elite"] {
            XCTAssertEqual(SIDLogoAsset.Kind(product: product), .ultimate64)
        }
        for product in ["C64 Ultimate", "C64 Ultimate Founder", "Commodore C64 Ultimate", "C64U"] {
            XCTAssertEqual(SIDLogoAsset.Kind(product: product), .c64Ultimate)
        }
        XCTAssertEqual(SIDLogoAsset.Kind(product: nil), .c64Ultimate)
        XCTAssertNotNil(SIDLogoAsset.image(for: .ultimate64))
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let pipeline = try SIDGenerativeRenderer.makePipeline(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var input = SIDGenerativeUniforms()
        input.viewport.w = 11
        input.energy.w = 0.6
        let c64 = try render(input, device: device, queue: queue, pipeline: pipeline)
        let u64 = try render(input, device: device, queue: queue, pipeline: pipeline, logoKind: .ultimate64)
        XCTAssertNotEqual(c64, u64)
        XCTAssertEqual(c64, try render(input, device: device, queue: queue, pipeline: pipeline))
        if let directory = ProcessInfo.processInfo.environment["STREAM64_VISUAL_PREVIEWS"] {
            try savePNG(u64, name: "Signal Collage Ultimate 64", directory: directory)
            try savePNG(c64, name: "Signal Collage C64 Ultimate", directory: directory)
        }
    }

    func testVoiceSnapshotKeepsDualSIDIdentityAndMutesDisconnectedVoice() {
        var channel = SIDVoiceChannel(id: 5, chipIndex: 1, voiceIndex: 2, bufferSize: 64, noteHistoryLength: 32)
        channel.registers.control = 0x41
        channel.registers.frequency = 4000
        channel.registers.pulseWidth = 2048
        _ = channel.synth.step(dt: 0.1, registers: channel.registers, neighborPhase: 0)
        let audible = SIDFilterRegisters(modeVolume: 15)
        var snapshot = SIDGenerativeUniforms.snapshot(mode: .sea, channels: [channel],
            filters: [audible, audible], rhythm: KAOSRhythmState(), glow: false)
        XCTAssertEqual(snapshot.style.z, 6)
        XCTAssertEqual(snapshot.voice0, .zero)
        XCTAssertGreaterThan(snapshot.voice5.x, 0)
        XCTAssertEqual(snapshot.voice5.z, Float(2048)/4095, accuracy: 0.0001)
        snapshot = .snapshot(mode: .sea, channels: [channel],
            filters: [audible, SIDFilterRegisters(modeVolume: 0x8f)],
            rhythm: KAOSRhythmState(), glow: false)
        XCTAssertEqual(snapshot.voice5.x, 0)
    }

    func testThirdSIDSnapshotAndRhythmKeepAllNineVoices() {
        var channel = SIDVoiceChannel(id: 8, chipIndex: 2, voiceIndex: 2, bufferSize: 8, noteHistoryLength: 6)
        channel.registers.control = 0x41
        channel.registers.frequency = 4000
        _ = channel.synth.step(dt: 0.1, registers: channel.registers, neighborPhase: 0)
        var rhythm = KAOSRhythmState()
        rhythm.advance(timestamp: 0, events: [], spectrumBars: [], channels: [channel])
        XCTAssertEqual(rhythm.activeVoiceMask, 256)
        XCTAssertEqual(rhythm.voiceLevels.count, 9)
        let input = SIDGenerativeUniforms.snapshot(mode: .sea, channels: [channel],
            filters: Array(repeating: SIDFilterRegisters(modeVolume: 15), count: 3), rhythm: rhythm, glow: false)
        XCTAssertEqual(input.style.z, 9)
        XCTAssertGreaterThan(input.voice8.x, 0)
    }

    func testPressureRenderBudgetAndWorkspaceModeRoundTrip() throws {
        let size = CGSize(width: 3840, height: 2160)
        let normal = SIDGenerativeRenderer.renderSize(for: size, underPressure: false)
        let reduced = SIDGenerativeRenderer.renderSize(for: size, underPressure: true)
        XCTAssertEqual(normal.width, 1000)
        XCTAssertEqual(reduced.width, 640)
        XCTAssertEqual(reduced.height, 360)
        let snapshot = SIDWindowLayoutSnapshot(entries: modes.map {
            SIDWindowLayoutEntry(mode: $0.rawValue, frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        }, savedAt: Date())
        let restored = try JSONDecoder().decode(SIDWindowLayoutSnapshot.self,
            from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.entries.compactMap { SIDVisualizationMode(rawValue: $0.mode) }, modes)
    }

    /// Exercises the actual Metal pipeline and verifies each effect responds
    /// to audio/voice input, rather than merely compiling an unused shader.
    func testAllEffectsRenderAndReactToSIDInput() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let pipeline = try SIDGenerativeRenderer.makePipeline(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var signatures = Set<Data>()
        for mode in modes {
            var quiet = SIDGenerativeUniforms.snapshot(mode: mode, channels: [], filters: [],
                                                       rhythm: KAOSRhythmState(), glow: false)
            quiet.viewport = SIMD4(640, 360, 4.5, quiet.viewport.w)
            var active = quiet
            active.energy = SIMD4(0.65, 0.4, 0.7, 0.7)
            active.style = SIMD4(0.6, 0.5, 3, 1)
            active.voice0 = SIMD4(0.85, 0.45, 0.25, 0)
            active.voice1 = SIMD4(0.65, 0.65, 0.75, 0)
            active.voice2 = SIMD4(0.5, 0.25, 0.5, 1)
            quiet.style = active.style // Isolate music response from glow/filter changes.
            active.rhythm = SIMD4(0.5, 1, 0.25, 1)
            let idle = try render(quiet, device: device, queue: queue, pipeline: pipeline)
            let pixels = try render(active, device: device, queue: queue, pipeline: pipeline)
            XCTAssertNotEqual(idle, pixels, "\(mode.rawValue) does not react")
            var lit = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let brightness = Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
                if brightness > 30 { lit += 1 }
            }
            XCTAssertGreaterThan(lit, 1000, "\(mode.rawValue) is blank")
            signatures.insert(Data(pixels))
            var dual = active
            dual.style.z = 6
            dual.voice3 = SIMD4(0.7, 0.6, 0.4, 0)
            dual.voice4 = SIMD4(0.9, 0.3, 0.6, 1)
            dual.voice5 = SIMD4(0.5, 0.8, 0.2, 0)
            XCTAssertNotEqual(pixels, try render(dual, device: device, queue: queue, pipeline: pipeline),
                              "\(mode.rawValue) ignores the second SID")
            var triple = dual
            triple.style.z = 9
            triple.voice6 = SIMD4(0.9, 0.2, 0.8, 1)
            triple.voice7 = SIMD4(0.3, 0.7, 0.2, 0)
            triple.voice8 = SIMD4(0.6, 0.4, 0.5, 0)
            XCTAssertNotEqual(try render(dual, device: device, queue: queue, pipeline: pipeline),
                              try render(triple, device: device, queue: queue, pipeline: pipeline),
                              "\(mode.rawValue) ignores the third SID")
            var later = active
            later.viewport.z += 1
            XCTAssertNotEqual(pixels, try render(later, device: device, queue: queue, pipeline: pipeline),
                              "\(mode.rawValue) does not animate")
            if let directory = ProcessInfo.processInfo.environment["STREAM64_VISUAL_PREVIEWS"] {
                try savePNG(pixels, name: mode.rawValue, directory: directory)
            }
        }
        XCTAssertEqual(signatures.count, modes.count, "Modes must render distinct scenes")
    }

    func testBlackholeMotionRespondsToAttacksWithoutRetriggeringHeldEnergy() {
        var motion = SIDPulseVortexVisualization.Motion()
        var input = SIDGenerativeUniforms()
        let idle = motion.advance(timestamp: 0, input: input)
        XCTAssertEqual(idle.w, 0)
        XCTAssertEqual(idle.z, 10, "Silence must not launch a shockwave")
        input.energy = SIMD4(0.7, 0.4, 1, 0.8)
        input.rhythm.y = 1
        let attack = motion.advance(timestamp: 0.1, input: input)
        XCTAssertEqual(attack.z, 0)
        XCTAssertEqual(attack.w, 1)
        let held = motion.advance(timestamp: 0.2, input: input)
        XCTAssertGreaterThan(held.z, 0)
        XCTAssertLessThan(held.w, attack.w, "Held energy must decay, not continuously flash")
        input.energy.z = 0
        _ = motion.advance(timestamp: 0.3, input: input)
        input.energy.z = 1
        let next = motion.advance(timestamp: 0.4, input: input)
        XCTAssertEqual(next.z, 0)
        XCTAssertGreaterThan(next.w, held.w)
        var quietMotion = SIDPulseVortexVisualization.Motion()
        _ = quietMotion.advance(timestamp: 0, input: SIDGenerativeUniforms())
        let quiet = quietMotion.advance(timestamp: 0.1, input: SIDGenerativeUniforms())
        XCTAssertGreaterThan(attack.x, quiet.x * 5, "Music must clearly accelerate the tunnel")
    }

    func testBlackholeAttackChangesImageAtFixedTime() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let pipeline = try SIDGenerativeRenderer.makePipeline(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var input = SIDGenerativeUniforms()
        input.viewport = SIMD4(640, 360, 4.5, 1)
        input.energy = SIMD4(0.5, 0.3, 0, 0.6)
        input.motion = SIMD4(1, 0.2, 10, 0)
        let before = try render(input, device: device, queue: queue, pipeline: pipeline)
        input.energy.z = 1
        input.rhythm.y = 1
        input.motion.z = 0.18
        input.motion.w = 0.8
        let attack = try render(input, device: device, queue: queue, pipeline: pipeline)
        var difference = 0
        for i in before.indices where i % 4 != 3 {
            difference += abs(Int(before[i]) - Int(attack[i]))
        }
        XCTAssertGreaterThan(Double(difference) / Double(640 * 360 * 3), 8,
                             "Attack response must be substantial even when animation time is frozen")
        if let directory = ProcessInfo.processInfo.environment["STREAM64_VISUAL_PREVIEWS"] {
            try savePNG(before, name: "Blackhole between beats", directory: directory)
            try savePNG(attack, name: "Blackhole attack", directory: directory)
        }
    }

    func testEchoFeedbackRetainsTransformsAndFadesEarlierFrames() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let pipeline = try SIDGenerativeRenderer.makePipeline(device: device, feedback: true)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var input = SIDGenerativeUniforms()
        input.viewport = SIMD4(640, 360, 2, 6)
        input.motion.x = 1.0 / 30
        input.energy = SIMD4(0.7, 0.4, 0.8, 0.8)
        input.rhythm.y = 1
        input.voice0 = SIMD4(1, 0.5, 0.5, 0)
        input.voice1 = SIMD4(0.8, 0.7, 0.5, 0)
        input.voice2 = SIMD4(0.6, 0.3, 0.5, 0)
        let empty = [UInt8](repeating: 0, count: 640*360*4)
        var history = empty
        for _ in 0..<40 {
            history = try render(input, device: device, queue: queue, pipeline: pipeline, previous: history)
            input.viewport.z += 1.0 / 30
        }
        if let directory = ProcessInfo.processInfo.environment["STREAM64_VISUAL_PREVIEWS"] {
            try savePNG(history, name: "Echo Tunnel feedback", directory: directory)
        }
        input.energy = .zero
        input.voice0 = .zero; input.voice1 = .zero; input.voice2 = .zero
        let retained = try render(input, device: device, queue: queue, pipeline: pipeline, previous: history)
        let fresh = try render(input, device: device, queue: queue, pipeline: pipeline, previous: empty)
        XCTAssertNotEqual(retained, fresh, "Earlier frames must survive when music falls quiet")
        XCTAssertNotEqual(retained, history, "Feedback must transform and decay")
        func excess(_ pixels: [UInt8]) -> Int {
            pixels.indices.filter { $0 % 4 != 3 }.reduce(0) { $0 + max(0, Int(pixels[$1])-Int(fresh[$1])) }
        }
        var faded = retained
        for _ in 0..<90 {
            faded = try render(input, device: device, queue: queue, pipeline: pipeline, previous: faded)
        }
        XCTAssertLessThan(excess(faded), excess(retained) / 2, "History must fade rather than accumulate forever")
    }

    private func render(_ uniforms: SIDGenerativeUniforms, device: MTLDevice,
                        queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
                        previous: [UInt8]? = nil, logoKind: SIDLogoAsset.Kind = .c64Ultimate) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 640, height: 360, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var copy = uniforms
        if let previous {
            let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: 640, height: 360, mipmapped: false)
            sourceDescriptor.usage = .shaderRead
            sourceDescriptor.storageMode = .shared
            let source = try XCTUnwrap(device.makeTexture(descriptor: sourceDescriptor))
            previous.withUnsafeBytes {
                source.replace(region: MTLRegionMake2D(0, 0, 640, 360), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: 640*4)
            }
            encoder.setFragmentTexture(source, index: 0)
        }
        encoder.setFragmentTexture(try SIDLogoAsset.texture(device: device, kind: logoKind), index: 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&copy, length: MemoryLayout<SIDGenerativeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "GPU failure")
        var bytes = [UInt8](repeating: 0, count: 640*360*4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 640*4,
                             from: MTLRegionMake2D(0, 0, 640, 360), mipmapLevel: 0)
        }
        return bytes
    }

    private func savePNG(_ bgra: [UInt8], name: String, directory: String) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640,
            pixelsHigh: 360, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 640*4, bitsPerPixel: 32))
        let output = try XCTUnwrap(bitmap.bitmapData)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            output[i] = bgra[i+2]; output[i+1] = bgra[i+1]
            output[i+2] = bgra[i]; output[i+3] = 255
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: url.appendingPathComponent(name + ".png"))
    }
}
