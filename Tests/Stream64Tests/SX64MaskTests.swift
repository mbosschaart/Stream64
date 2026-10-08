import XCTest
import AppKit
import MetalKit
@testable import Stream64

final class SX64MaskTests: XCTestCase {
    @MainActor
    func testReferenceMaskRendersDistinctDots() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        // The composed variant uses the same CRT filter math as the viewer.
        let library = try device.makeLibrary(
            source: MetalFrameRenderer.composedShaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentCRTTube")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let width = 1280, height = 960
        func texture(_ w: Int, _ h: Int) throws -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = [.shaderRead, .renderTarget]
            return try XCTUnwrap(device.makeTexture(descriptor: desc))
        }
        let source = try texture(384, 272)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 384, pixelsHigh: 272, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 384 * 4, bitsPerPixel: 32))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.1, green: 0.65, blue: 0.7, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 384, height: 272)).fill()
        NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 22, y: 16, width: 340, height: 238)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.15,
                                      blue: 0.6, alpha: 1)]
        ("**** SX-64 BASIC V2.0 ****" as NSString).draw(
            at: NSPoint(x: 44, y: 229), withAttributes: attributes)
        ("64K RAM SYSTEM  38911 BYTES FREE" as NSString).draw(
            at: NSPoint(x: 31, y: 207), withAttributes: attributes)
        ("READY.\nPRINT \"PHOSPHOR DOTS\"" as NSString).draw(
            at: NSPoint(x: 31, y: 164), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let rgba = try XCTUnwrap(bitmap.bitmapData)
        var bgra = [UInt8](repeating: 0, count: 384 * 272 * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            bgra[i] = rgba[i + 2]; bgra[i + 1] = rgba[i + 1]
            bgra[i + 2] = rgba[i]; bgra[i + 3] = 255
        }
        bgra.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, 384, 272), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 384 * 4)
        }
        let historyDesc = MTLTextureDescriptor()
        historyDesc.textureType = .type2DArray
        historyDesc.pixelFormat = .bgra8Unorm
        historyDesc.width = 384; historyDesc.height = 272
        historyDesc.arrayLength = 12; historyDesc.usage = [.shaderRead]
        let history = try XCTUnwrap(device.makeTexture(descriptor: historyDesc))
        let sampler = try XCTUnwrap(device.makeSamplerState(
            descriptor: MTLSamplerDescriptor()))
        func render(_ monitor: BezelChoice, mask: Float = 0.5, type: CRTMaskType = .automatic, brightness: Float = 0.5, contrast: Float = 0.5, bloom: Float = 0, signal: Float = 0, previewName: String? = nil) throws -> [UInt8] {
            var uniforms = MetalFrameRenderer.Uniforms(
                scale: SIMD2(1, 1), reflection: 0, signal: signal, time: 0,
                brightness: brightness, contrast: contrast, saturation: 0.5, tint: 0.5,
                phosphorColor: 0, dirtyGlass: 0,
                maskPitch: Float(width) / monitor.phosphorTriadsAcrossScreen,
                maskType: type.shaderValue(for: monitor),
                historyHead: 0, historyValidCount: 0, historyPhase: 0,
                powerOff: 0, bezelSurfaceMode: 0, scanlineStrength: 0,
                bloomAmount: bloom, maskIntensity: mask, barrelDistortion: 0.5,
                motionBlend: 1)
            let target = try texture(width, height)
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
            encoder.setFragmentTexture(source, index: 1)
            encoder.setFragmentTexture(source, index: 2)
            encoder.setFragmentTexture(history, index: 3)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&pixels, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            if let directory = ProcessInfo.processInfo.environment["STREAM64_CRT_PREVIEWS"], mask > 0 || bloom > 0 || previewName != nil {
                let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
                let bytes = try XCTUnwrap(image.bitmapData)
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    bytes[i] = pixels[i + 2]; bytes[i + 1] = pixels[i + 1]
                    bytes[i + 2] = pixels[i]; bytes[i + 3] = 255
                }
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent(previewName ?? (bloom > 0 ? "brightness-\(brightness)-contrast-\(contrast).png" : (type == .automatic ? (monitor == .sx64 ? "SX64.png" : "1702.png") : "\(type).png"))))
            }
            return pixels
        }
        // Exercise all explicit geometries through the production shader.
        var masks = Set<Data>()
        for type in [CRTMaskType.shadowMask, .apertureGrille, .slotMask] {
            masks.insert(Data(try render(.sx64, type: type)))
        }
        XCTAssertEqual(masks.count, 3, "All mask geometries must render distinctly")
        let sx64 = try render(.sx64)
        let desktop = try render(.c1702)
        let unmasked = try render(.sx64, mask: 0)
        // Blank central screen: check actual dark interstices, independent
        // of the source text, curvature and shared vignette shading.
        func luminanceRange(_ pixels: [UInt8]) -> Double {
            var values: [Double] = []
            for y in 550..<590 {
                for x in 550..<650 {
                    let i = (y * width + x) * 4
                    values.append((Double(pixels[i]) + Double(pixels[i + 1])
                                   + Double(pixels[i + 2])) / 3)
                }
            }
            return values.max()! - values.min()!
        }
        XCTAssertGreaterThan(luminanceRange(sx64), luminanceRange(desktop) + 20)
        XCTAssertGreaterThan(luminanceRange(sx64), luminanceRange(unmasked) + 20)

        // A saturated white core on black exposes the previous limitation:
        // increasing drive must grow the surrounding light after core clipping.
        var highlight = [UInt8](repeating: 0, count: 384 * 272 * 4)
        for i in stride(from: 0, to: highlight.count, by: 4) { highlight[i + 3] = 255 }
        for y in 128..<144 {
            for x in 184..<200 {
                let i = (y * 384 + x) * 4
                highlight[i] = 255; highlight[i + 1] = 255; highlight[i + 2] = 255
            }
        }
        highlight.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, 384, 272), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 384 * 4)
        }
        let neutral = try render(.c1702, mask: 0, bloom: 0.5)
        let contrastMid = try render(.c1702, mask: 0, contrast: 0.75, bloom: 0.5)
        let contrastHigh = try render(.c1702, mask: 0, contrast: 1, bloom: 0.5)
        let brightnessMid = try render(.c1702, mask: 0, brightness: 0.75, bloom: 0.5)
        let brightnessHigh = try render(.c1702, mask: 0, brightness: 1, bloom: 0.5)
        let bloomOff = try render(.c1702, mask: 0, contrast: 1, bloom: 0)
        func mean(_ pixels: [UInt8], x: Range<Int>) -> Double {
            var total = 0.0
            for y in 470..<490 {
                for column in x {
                    let i = (y * width + column) * 4
                    total += (Double(pixels[i]) + Double(pixels[i + 1])
                              + Double(pixels[i + 2])) / 3
                }
            }
            return total / Double(20 * x.count)
        }
        func halo(_ pixels: [UInt8]) -> Double {
            mean(pixels, x: 602..<610) - mean(pixels, x: 450..<458)
        }
        XCTAssertGreaterThan(halo(contrastHigh), halo(contrastMid) + 1)
        XCTAssertGreaterThan(halo(contrastMid), halo(neutral) + 1)
        XCTAssertGreaterThan(halo(brightnessHigh), halo(brightnessMid) + 1)
        XCTAssertGreaterThan(halo(brightnessMid), halo(neutral) + 1)
        XCTAssertGreaterThan(halo(contrastHigh), halo(bloomOff) + 1)

        // Equal-luminance red/grey boundary isolates chroma spread from
        // ordinary brightness blur, bloom, masks and scanlines.
        var colorEdge = [UInt8](repeating: 76, count: 384 * 272 * 4)
        for i in stride(from: 0, to: colorEdge.count, by: 4) { colorEdge[i + 3] = 255 }
        for y in 0..<272 {
            for x in 184..<190 {
                let i = (y * 384 + x) * 4
                colorEdge[i] = 0; colorEdge[i + 1] = 0; colorEdge[i + 2] = 255
            }
        }
        colorEdge.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, 384, 272), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 384 * 4)
        }
        let svideo = try render(.c1702, mask: 0, previewName: "S-Video.png")
        let composite = try render(.c1702, mask: 0, signal: 1, previewName: "Composite.png")
        func chroma(_ pixels: [UInt8]) -> Double {
            var total = 0.0
            for y in 470..<490 {
                for x in 595..<603 {
                    let i = (y * width + x) * 4
                    let rgb = [pixels[i], pixels[i + 1], pixels[i + 2]]
                    total += Double(rgb.max()!) - Double(rgb.min()!)
                }
            }
            return total / 160
        }
        XCTAssertGreaterThan(chroma(composite), chroma(svideo) + 10,
                             "Composite colour must bleed several source pixels beyond the edge")
        XCTAssertLessThan(abs(mean(composite, x: 595..<603) - mean(svideo, x: 595..<603)), 10,
                          "Chroma spread must retain the separate luminance edge")


    }
}
