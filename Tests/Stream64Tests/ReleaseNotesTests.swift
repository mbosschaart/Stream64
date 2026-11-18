import XCTest
import SwiftUI
@testable import Stream64

final class ReleaseNotesTests: XCTestCase {
    func testParsesGitHubReleaseBlocks() {
        let body = """
        ## 0.138b — 2026-09-24\r
        \r
        Intro line one\r
        continues here.\r
        \r
        ### Highlights\r
        \r
        - **Bold lead.** Rest of `item`.\r
        - Second item\r
          wrapped onto a new line.\r
          - Nested item\r
        1. First step\r
        \r
        ---\r
        ```\r
        code block\r
        ```\r
        """
        XCTAssertEqual(ReleaseNotesBlock.parse(body), [
            .heading(level: 2, text: "0.138b — 2026-09-24"),
            .paragraph("Intro line one continues here."),
            .heading(level: 3, text: "Highlights"),
            .bullet(indent: 0, text: "**Bold lead.** Rest of `item`."),
            .bullet(indent: 0, text: "Second item wrapped onto a new line."),
            .bullet(indent: 1, text: "Nested item"),
            .numbered(number: "1", text: "First step"),
            .rule,
            .code("code block"),
        ])
    }

    func testBoldParagraphIsNotABullet() {
        XCTAssertEqual(
            ReleaseNotesBlock.parse("**Version 0.136b** matches build 136."),
            [.paragraph("**Version 0.136b** matches build 136.")])
    }

    /// Writes a preview of the rendered notes when STREAM64_NOTES_PREVIEW
    /// names an output PNG path; a no-op otherwise.
    @MainActor
    func testRenderPreviewWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["STREAM64_NOTES_PREVIEW"],
              let source = ProcessInfo.processInfo.environment["STREAM64_NOTES_SOURCE"]
        else { throw XCTSkip("preview not requested") }
        let markdown = try String(contentsOfFile: source, encoding: .utf8)
        let renderer = ImageRenderer(content:
            ReleaseNotesView(markdown: markdown)
                .padding(12)
                .frame(width: 532)
                .background(Color.white)
                .environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?
            .representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
