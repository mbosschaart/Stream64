import XCTest
import MetalKit
@testable import Stream64

final class SIDMusicCompoTests: XCTestCase {
    func testCompoDeckUsesAbstractEffectsAndCannotRecurse() {
        XCTAssertFalse(SIDVisualizationMode.individualModes.contains(.musicCompo))
        XCTAssertFalse(SIDVisualizationMode.individualModes.contains(.clubMode))
        XCTAssertTrue(SIDVisualizationMode.activeModes.contains(.musicCompo))
        XCTAssertEqual(SIDVisualizationMode.compoModes.count, 16)
        var sequence = SIDClubModeSequence(modes: SIDVisualizationMode.compoModes)
        var random = SystemRandomNumberGenerator()
        var seen = Set<SIDVisualizationMode>()
        for _ in 0..<200 {
            let cue = sequence.next(using: &random)
            XCTAssertTrue(SIDVisualizationMode.compoModes.contains(cue.mode))
            XCTAssertTrue(cue.isBurst ? cue.duration == 0.2 : (0.5...3).contains(cue.duration))
            seen.insert(cue.mode)
        }
        XCTAssertEqual(seen, Set(SIDVisualizationMode.compoModes))
        let needs = SIDEngineNeeds(mode: .musicCompo)
        XCTAssertTrue(needs.needsKAOSRhythm)
        XCTAssertTrue(needs.needsAudioTap)
        XCTAssertFalse(needs.needsLissajousPoints)
        XCTAssertTrue(needs.usesSpectrogramHistory)
    }

    @MainActor
    func testAdditionalScenesRenderDirectlyOnGPUAtVideoResolution() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let composer = try SIDMusicCompoComposer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func texture(_ format: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let palette = try texture(.rgba8Unorm, width: 16, height: 1)
        let blackPalette = Data(repeating: 0, count: 64)
        blackPalette.withUnsafeBytes { palette.replace(region: MTLRegionMake2D(0, 0, 16, 1),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        var voice = SIDVoiceChannel(id: 0, chipIndex: 0, voiceIndex: 0, bufferSize: 32, noteHistoryLength: 6)
        for index in 0..<32 { voice.push(sample: sin(Float(index) * 0.5) * 0.8, envelope: 0.8) }
        var active = SIDGenerativeUniforms()
        active.energy = SIMD4(0.6, 0.4, 0.8, 0.7)
        active.voice0 = SIMD4(0.8, 0.5, 0.5, 0)
        active.voice1 = active.voice0; active.voice2 = active.voice0
        let history = Array(repeating: (0..<48).map { Float($0 + 1) / 48 }, count: 14)
        var signatures = Set<Data>()
        for mode in [SIDVisualizationMode.barField3D, .sidShowcase, .colorfulWaveform, .spectrum, .waterfall3D, .spectrogram] {
            composer.performanceScene = try XCTUnwrap(SIDPerformanceGPU.Scene(mode: mode))
            for height in [VideoReceiver.palHeight, VideoReceiver.ntscHeight] {
                let width = VideoReceiver.width
                let video = try texture(.r8Uint, width: width, height: height)
                let black = Data(repeating: 0, count: width * height)
                black.withUnsafeBytes { video.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width) }
                var outputs: [Data] = []
                for isActive in [false, true] {
                    composer.input = isActive ? active : SIDGenerativeUniforms()
                    composer.channels = isActive ? [voice] : []
                    composer.spectrumHistory = isActive ? history : []
                    let command = try XCTUnwrap(queue.makeCommandBuffer())
                    let result = try XCTUnwrap(composer.encode(command: command, video: video, palette: palette, at: 100))
                    XCTAssertEqual(result.width, width); XCTAssertEqual(result.height, height)
                    let readback = try texture(.bgra8Unorm, width: width, height: height)
                    let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
                    blit.copy(from: result, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                        sourceSize: .init(width: width, height: height, depth: 1), to: readback,
                        destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
                    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed)
                    var pixels = [UInt8](repeating: 0, count: width * height * 4)
                    readback.getBytes(&pixels, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                    outputs.append(Data(pixels))
                    if isActive {
                        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains {
                            pixels[$0] > 10 || pixels[$0 + 1] > 10 || pixels[$0 + 2] > 10
                        }, "\(mode.displayName) must reach the composite output")
                    }
                }
                XCTAssertNotEqual(outputs[0], outputs[1], mode.displayName)
                if height == VideoReceiver.palHeight { signatures.insert(outputs[1]) }
            }
        }
        XCTAssertEqual(signatures.count, 6)
    }

    @MainActor
    func testComposedVideoFilterPipelinesCompile() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        XCTAssertNotNil(MetalFrameRenderer(mtkView: MTKView(), composedFrames: true))
    }

    func testVideoOpacityBlendsBeforeEveryVideoFilter() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = VideoReceiver.width, height = VideoReceiver.palHeight
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.storageMode = .shared
            d.usage = [.shaderRead, .renderTarget]
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let video = try texture(.r8Uint, width, height)
        let indices: [UInt8] = (0..<(width * height)).map { index in
            let row = index / width / 8
            let column = (index % width) / 8
            return UInt8((row + column) % 2)
        }
        indices.withUnsafeBytes { video.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width) }
        let palette = try texture(.rgba8Unorm, 16, 1)
        var colors = Array(repeating: UInt8(0), count: 64)
        colors[0] = 64; colors[1] = 100; colors[2] = 180; colors[3] = 255
        colors[4] = 180; colors[5] = 60; colors[6] = 80; colors[7] = 255
        colors.withUnsafeBytes { palette.replace(region: MTLRegionMake2D(0, 0, 16, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 64) }
        let composer = try SIDMusicCompoComposer(device: device)
        composer.input.viewport.w = 4 // Pixel Riptide, deterministic input and time.
        composer.input.energy = SIMD4(0.4, 0.3, 0.2, 0.5)
        composer.input.voice0 = SIMD4(0.8, 0.5, 0.5, 0)
        let readback = try texture(.bgra8Unorm, width, height)
        func pixels(_ source: MTLTexture, command: MTLCommandBuffer) throws -> [UInt8] {
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: .init(width: width, height: height, depth: 1), to: readback,
                destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
            blit.endEncoding()
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var bytes = Array(repeating: UInt8(0), count: width * height * 4)
            readback.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }
        var blends: [[UInt8]] = []
        for opacity: Float in [0, 0.5, 1] {
            composer.videoOpacity = opacity
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let result = try XCTUnwrap(composer.encode(command: command, video: video, palette: palette, at: 100))
            XCTAssertEqual(result.width, video.width)
            XCTAssertEqual(result.height, video.height)
            blends.append(try pixels(result, command: command))
        }
        XCTAssertNotEqual(blends[0], blends[1])
        XCTAssertNotEqual(blends[1], blends[2])
        for index in stride(from: 0, to: blends[0].count, by: 4) {
            for component in 0..<3 {
                XCTAssertLessThanOrEqual(blends[0][index + component], blends[1][index + component])
                XCTAssertLessThanOrEqual(blends[1][index + component], blends[2][index + component])
            }
        }
        // Palette conversion belongs to the foreground, before video blending.
        composer.c64Palette = true
        composer.videoOpacity = 0
        let paletteCommand = try XCTUnwrap(queue.makeCommandBuffer())
        let paletteResult = try XCTUnwrap(composer.encode(command: paletteCommand, video: video, palette: palette, at: 100))
        let palettePixels = try pixels(paletteResult, command: paletteCommand)
        let allowed = C64Palette.peptoPALColors
        XCTAssertNotEqual(palettePixels, blends[0])
        for index in stride(from: 0, to: palettePixels.count, by: 4) {
            XCTAssertTrue(allowed.contains {
                $0.blue == palettePixels[index] && $0.green == palettePixels[index+1] && $0.red == palettePixels[index+2]
            })
        }
        composer.videoOpacity = 1
        let mixedCommand = try XCTUnwrap(queue.makeCommandBuffer())
        let mixedResult = try XCTUnwrap(composer.encode(command: mixedCommand, video: video, palette: palette, at: 100))
        let mixedPixels = try pixels(mixedResult, command: mixedCommand)
        var largestBlendError = 0
        for index in stride(from: 0, to: mixedPixels.count, by: 4) {
            let paletteIndex = Int(indices[index/4])*4
            let bg = [colors[paletteIndex+2],colors[paletteIndex+1],colors[paletteIndex]].map { Float($0)/255 }
            for component in 0..<3 {
                let fg = Float(palettePixels[index+component])/255
                let expected = Int(((1-(1-fg)*(1-bg[component]))*255).rounded())
                largestBlendError = max(largestBlendError, abs(Int(mixedPixels[index+component])-expected))
            }
        }
        XCTAssertLessThanOrEqual(largestBlendError, 1)
        composer.c64Palette = false
        // Run the actual production RGB shader variants on the blended source.
        let library = try device.makeLibrary(source: MetalFrameRenderer.composedShaderSource, options: nil)
        let sourceCommand = try XCTUnwrap(queue.makeCommandBuffer())
        let source = try XCTUnwrap(composer.encode(command: sourceCommand, video: video, palette: palette, at: 100))
        sourceCommand.commit(); sourceCommand.waitUntilCompleted()
        let historyDescriptor = MTLTextureDescriptor()
        historyDescriptor.textureType = .type2DArray
        historyDescriptor.pixelFormat = .bgra8Unorm
        historyDescriptor.width = width; historyDescriptor.height = height
        historyDescriptor.arrayLength = 8
        historyDescriptor.usage = [.shaderRead]
        let history = try XCTUnwrap(device.makeTexture(descriptor: historyDescriptor))
        let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: MTLSamplerDescriptor()))
        var uniforms = MetalFrameRenderer.Uniforms(scale: SIMD2(1, 1), reflection: 0, signal: 0,
            time: 0, brightness: 0.5, contrast: 0.5, saturation: 0.5, tint: 0.5,
            phosphorColor: 0, dirtyGlass: 0, maskPitch: 1, historyHead: 0,
            historyValidCount: 0, historyPhase: 0, powerOff: 0, bezelSurfaceMode: 0,
            scanlineStrength: 0.5, bloomAmount: 0.5, maskIntensity: 0.5, barrelDistortion: 0.5, motionBlend: 1)
        var images = Set<Data>()
        for name in ["fragmentMain", "fragmentSmooth", "fragmentCRT", "fragmentCRTTube"] {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let target = try texture(.bgra8Unorm, width, height)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalFrameRenderer.Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalFrameRenderer.Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentTexture(palette, index: 1)
            encoder.setFragmentTexture(palette, index: 2)
            encoder.setFragmentTexture(history, index: 3)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            let result = try pixels(target, command: command)
            XCTAssertTrue(stride(from: 0, to: result.count, by: 4).contains { result[$0] > 5 })
            images.insert(Data(result))
            if let directory = ProcessInfo.processInfo.environment["STREAM64_COMPO_PREVIEWS"] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: width * 4, bitsPerPixel: 32))
                let destination = try XCTUnwrap(bitmap.bitmapData)
                for pixel in stride(from: 0, to: result.count, by: 4) {
                    destination[pixel] = result[pixel + 2]
                    destination[pixel + 1] = result[pixel + 1]
                    destination[pixel + 2] = result[pixel]
                    destination[pixel + 3] = 255
                }
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
            }
        }
        XCTAssertGreaterThanOrEqual(images.count, 3, "CRT filters must change the combined image")
        // Resolution changes must rebuild effect/feedback textures to match
        // the video signal, never the fullscreen window's drawable size.
        for newHeight in [VideoReceiver.ntscHeight, VideoReceiver.palHeight] {
            let resized = try texture(.r8Uint, VideoReceiver.width, newHeight)
            let black = Data(repeating: 0, count: VideoReceiver.width * newHeight)
            black.withUnsafeBytes { resized.replace(region: MTLRegionMake2D(0, 0, VideoReceiver.width, newHeight),
                mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: VideoReceiver.width) }
            composer.input.viewport.w = 6 // Exercise Echo Tunnel's resized feedback too.
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let result = try XCTUnwrap(composer.encode(command: command, video: resized, palette: palette, at: 101))
            XCTAssertEqual(result.width, VideoReceiver.width)
            XCTAssertEqual(result.height, newHeight)
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
        }
    }
}
