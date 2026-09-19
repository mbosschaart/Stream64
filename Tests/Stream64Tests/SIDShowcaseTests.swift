import XCTest
import SwiftUI
import MetalKit
import AppKit
@testable import Stream64

final class SIDShowcaseTests: XCTestCase {
    func testAllSixAssetsStayAssignedAndVisitEveryVoice() {
        XCTAssertEqual(SIDShowcaseLayout.resources.count, 6)
        XCTAssertEqual(SIDShowcaseLayout.images.compactMap { $0 }.count, 6)
        for count in [3, 6] {
            for image in 0..<6 {
                let assignments = (0..<count).map {
                    SIDShowcaseLayout.voice(for: image, count: count, time: Double($0)*4)
                }
                XCTAssertEqual(Set(assignments), Set(0..<count))
                XCTAssertEqual(SIDShowcaseLayout.voice(for: image, count: count, time: 3.99), image % count)
            }
        }
        for turn in 0..<6 {
            let mapping = (0..<6).map { SIDShowcaseLayout.voice(for: $0, count: 6, time: Double(turn) * 4) }
            XCTAssertEqual(Set(mapping), Set(0..<6), "All six voices need simultaneous representation")
        }
        XCTAssertEqual(SIDVisualizationMode.sidShowcase.displayName, "SID Showcase")
        for size in [CGSize(width: 900, height: 500), CGSize(width: 1920, height: 1080),
                     CGSize(width: 600, height: 900)] {
            let bounds = CGRect(origin: .zero, size: size)
            for image in 0..<6 {
                XCTAssertTrue(bounds.contains(SIDShowcaseLayout.slot(for: image, size: size)))
            }
        }
        XCTAssertTrue(SIDVisualizationMode.individualModes.contains(.sidShowcase))
        XCTAssertEqual(SIDVisualizationMode(rawValue: "SID Slideshow"), .sidShowcase)
    }

    @MainActor
    func testStageRendersAndChangesWithVoiceActivityAndRotation() throws {
        var input = SIDGenerativeUniforms()
        input.style.z = 6
        input.style.w = 1
        let quiet = try render(input, time: 1, size: CGSize(width: 900, height: 600), name: "quiet")
        input.voice0 = SIMD4(0.9, 0.3, 0.4, 0)
        input.voice1 = SIMD4(0.7, 0.6, 0.2, 1)
        input.voice2 = SIMD4(0.6, 0.8, 0.7, 0)
        input.voice3 = SIMD4(0.8, 0.5, 0.5, 0)
        input.voice4 = SIMD4(0.4, 0.7, 0.3, 1)
        input.voice5 = SIMD4(0.95, 0.2, 0.8, 0)
        input.energy = SIMD4(0.7, 0.5, 0.8, 0.8)
        input.rhythm.x = 0.7
        let active = try render(input, time: 1, size: CGSize(width: 900, height: 600), name: "active")
        XCTAssertNotEqual(quiet, active)
        XCTAssertNotEqual(active, try render(input, time: 5, size: CGSize(width: 900, height: 600), name: "rotated"))
        _ = try render(input, time: 1, size: CGSize(width: 1920, height: 1080), name: "fullscreen")
        _ = try render(input, time: 1, size: CGSize(width: 600, height: 900), name: "portrait")
    }

    @MainActor
    private func render(_ input: SIDGenerativeUniforms, time: Double, size: CGSize, name: String) throws -> Data {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let renderer = try SIDPerformanceGPU(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(renderer.encode(command: command, target: texture, scene: .showcase,
            input: input, channels: [], history: [], time: Float(time)))
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        texture.getBytes(&bytes, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w,
            pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w*4, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for p in stride(from: 0, to: bytes.count, by: 4) {
            pixels[p] = bytes[p+2]; pixels[p+1] = bytes[p+1]; pixels[p+2] = bytes[p]; pixels[p+3] = 255
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["STREAM64_SHOWCASE_PREVIEWS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent(name + ".png"))
        }
        return png
    }
}
