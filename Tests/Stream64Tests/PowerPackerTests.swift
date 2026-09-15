import XCTest
@testable import Stream64

final class PowerPackerTests: XCTestCase {
    /// Validated against `unar`: decrunches to "A" (literal-only path).
    private let packedA: [UInt8] = [
        0x50, 0x50, 0x32, 0x30, // "PP20"
        0x09, 0x0A, 0x0C, 0x0D, // offset table
        0x04, 0x10, // bitstream
        0x00, 0x00, 0x01, 0x00, // length = 1, skip = 0
    ]

    /// Validated against `unar`: decrunches to "AAA" (literal + back-reference).
    private let packedAAA: [UInt8] = [
        0x50, 0x50, 0x32, 0x30, // "PP20"
        0x01, 0x0A, 0x0C, 0x0D, // offset table
        0x04, 0x10, // bitstream
        0x00, 0x00, 0x03, 0x00, // length = 3, skip = 0
    ]

    func testDetectsPP20Magic() {
        XCTAssertTrue(PowerPacker.isPP20(Data(packedA)))
        XCTAssertFalse(PowerPacker.isPP20(Data("M.K.".utf8)))
        XCTAssertFalse(PowerPacker.isPP20(Data()))
    }

    func testDecrunchesLiteralOnly() throws {
        XCTAssertEqual(
            try PowerPacker.decrunch(Data(packedA)),
            Data("A".utf8))
    }

    func testDecrunchesWithBackReference() throws {
        XCTAssertEqual(
            try PowerPacker.decrunch(Data(packedAAA)),
            Data("AAA".utf8))
    }

    func testDecrunchIfNeededPassesThroughPlainData() throws {
        let plain = Data([0x00, 0x01, 0x4D, 0x2E, 0x4B, 0x2E])
        XCTAssertEqual(try PowerPacker.decrunchIfNeeded(plain), plain)
    }

    func testRejectsBadMagicAndTruncation() {
        XCTAssertThrowsError(
            try PowerPacker.decrunch(Data([0x50, 0x50, 0x31, 0x31]
                + [UInt8](repeating: 0, count: 8)))
        ) {
            XCTAssertEqual($0 as? PowerPacker.Error, .notPowerPacker)
        }

        var truncated = packedA
        truncated[12] = 0x0A // claim 10 output bytes
        XCTAssertThrowsError(try PowerPacker.decrunch(Data(truncated)))
    }

    func testDecrunchesRealPowerpackedMOD() throws {
        let url = URL(fileURLWithPath:
            "/Users/martijn/Downloads/Update2020/MODS/MODS - My classics--/TEKKNO-Rhythm (powerpacked).MOD")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("Sample Powerpacked MOD not present on this machine")
        }
        let packed = try Data(contentsOf: url)
        XCTAssertTrue(PowerPacker.isPP20(packed))
        let mod = try PowerPacker.decrunch(packed)
        XCTAssertEqual(mod.count, 129_414)
        XCTAssertEqual(mod.subdata(in: 1080..<1084), Data("M.K.".utf8))
        let title = String(
            decoding: mod.prefix(20).prefix(while: { $0 != 0 }),
            as: UTF8.self)
        XCTAssertEqual(title, "the tekkno-rythm")
    }
}
