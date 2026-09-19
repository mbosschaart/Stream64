import XCTest
import SwiftUI
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
        let renderer = ImageRenderer(content: SIDShowcaseStage(input: input, time: time)
            .frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["STREAM64_SHOWCASE_PREVIEWS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent(name + ".png"))
        }
        return png
    }
}
