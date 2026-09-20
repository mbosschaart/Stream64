import XCTest
import SwiftUI
import MetalKit
@testable import Stream64

final class SIDVisualizationPaletteTests: XCTestCase {
    func testGPUMapsToExactlyTheC64PaletteAndPreservesItsColors() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let library = try device.makeLibrary(URL: SIDVisualizationPalette.libraryURL)
        XCTAssertNotNil(library.makeFunction(name: "sidC64ColorEffect"))
        let pass = try SIDVisualizationPalettePass(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 256, height: 1, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let colors = C64Palette.peptoPALColors
        var bytes = (0..<256).flatMap { i -> [UInt8] in
            if i < 16 { let c = colors[i]; return [c.blue, c.green, c.red, 255] }
            return [UInt8(i), UInt8((i * 7) % 256), UInt8((i * 13) % 256), 255]
        }
        source.replace(region: MTLRegionMake2D(0,0,256,1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 1024)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pass.encode(command: command, source: source, target: output))
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var mapped = [UInt8](repeating: 0, count: 1024)
        output.getBytes(&mapped, bytesPerRow: 1024, from: MTLRegionMake2D(0,0,256,1), mipmapLevel: 0)
        XCTAssertEqual(Array(mapped.prefix(64)), Array(bytes.prefix(64)))
        for i in stride(from: 0, to: mapped.count, by: 4) {
            XCTAssertTrue(colors.contains { $0.blue == mapped[i] && $0.green == mapped[i+1] && $0.red == mapped[i+2] })
        }
        let small = try XCTUnwrap(pass.sourceTexture(width: 384, height: 272))
        XCTAssertTrue(small === pass.sourceTexture(width: 384, height: 272))
        XCTAssertEqual(pass.sourceTexture(width: 1000, height: 600)?.width, 1000)
    }

    @MainActor
    func testSwiftUIInstrumentPaletteRenders() throws {
        let content = VStack {
            Text("C64 PALETTE · SID INSTRUMENTS").foregroundStyle(.white)
            LinearGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple],
                startPoint: .leading, endPoint: .trailing)
            SIDPianoKeyboardView(channels: (0..<3).map {
                var channel = SIDVoiceChannel(id: $0, chipIndex: 0, voiceIndex: $0, bufferSize: 32, noteHistoryLength: 8)
                channel.registers.control = 0x41
                channel.registers.frequency = UInt16(3000 + $0 * 2000)
                return channel
            })
        }.padding().frame(width: 640, height: 360).background(.black)
            .drawingGroup(opaque: true, colorMode: .nonLinear)
            .colorEffect(SIDVisualizationPalette.colorEffect)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Sample the solid interior of the gradient, clear of text/antialiasing.
        let allowed = C64Palette.peptoPALColors
        for x in stride(from: 30, to: 610, by: 20) {
            let c = try XCTUnwrap(bitmap.colorAt(x: x, y: 60))
            XCTAssertTrue(allowed.contains {
                abs(Double($0.red)/255-c.redComponent) < 0.025 &&
                abs(Double($0.green)/255-c.greenComponent) < 0.025 &&
                abs(Double($0.blue)/255-c.blueComponent) < 0.025
            }, "Unexpected gradient colour at \(x): \(c)")
        }
        if let directory = ProcessInfo.processInfo.environment["STREAM64_VISUAL_PREVIEWS"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("C64 Palette Instruments.png"))
        }
    }
}
