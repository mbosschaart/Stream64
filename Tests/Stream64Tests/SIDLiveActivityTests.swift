import XCTest
@testable import Stream64

final class SIDLiveActivityTests: XCTestCase {
    private func startVoice(_ detector: inout SIDLiveActivityDetector, chip: Int) {
        detector.record(chip: chip, offset: 0, value: 64)
        detector.record(chip: chip, offset: 1, value: 20)
        detector.record(chip: chip, offset: 24, value: 15)
        detector.record(chip: chip, offset: 4, value: 0x21)
    }
    private func advance(_ detector: inout SIDLiveActivityDetector, from: Int, through: Int,
                         received: Bool = true, healthy: Bool = true) {
        for tick in from...through {
            detector.advance(at: Double(tick) / 10, traceReceived: received, traceHealthy: healthy)
        }
    }

    func testPrimaryActivitySettlesThenExpandsToThreeChips() {
        var d = SIDLiveActivityDetector(chipCount: 3)
        startVoice(&d, chip: 0)
        advance(&d, from: 0, through: 30)
        XCTAssertNil(d.activeChips)
        advance(&d, from: 31, through: 50)
        XCTAssertEqual(d.activeChips, [0])
        startVoice(&d, chip: 1)
        advance(&d, from: 51, through: 53)
        XCTAssertEqual(d.activeChips, [0, 1])
        startVoice(&d, chip: 2)
        advance(&d, from: 54, through: 56)
        XCTAssertEqual(d.activeChips, [0, 1, 2])
    }

    func testInitializationAndRepeatedZeroWritesDoNotActivateChip() {
        var d = SIDLiveActivityDetector(chipCount: 2)
        startVoice(&d, chip: 0)
        for tick in 0...80 {
            for offset in 0..<25 { d.record(chip: 1, offset: offset, value: 0) }
            d.advance(at: Double(tick)/10, traceReceived: true, traceHealthy: true)
        }
        XCTAssertEqual(d.activeChips, [0])
    }

    func testSustainedVoiceRemainsWithoutFurtherRegisterWrites() {
        var d = SIDLiveActivityDetector(chipCount: 2)
        startVoice(&d, chip: 0); startVoice(&d, chip: 1)
        advance(&d, from: 0, through: 600)
        XCTAssertEqual(d.activeChips, [0, 1])
    }

    func testInactiveChipRetiresSlowlyAndReturns() {
        var d = SIDLiveActivityDetector(chipCount: 2)
        startVoice(&d, chip: 0); startVoice(&d, chip: 1)
        advance(&d, from: 0, through: 50)
        d.record(chip: 1, offset: 4, value: 0x20)
        advance(&d, from: 51, through: 340)
        XCTAssertEqual(d.activeChips, [0, 1])
        advance(&d, from: 341, through: 360)
        XCTAssertEqual(d.activeChips, [0])
        startVoice(&d, chip: 1)
        advance(&d, from: 361, through: 363)
        XCTAssertEqual(d.activeChips, [0, 1])
    }

    func testTraceLossAndDroppedPacketsNeverAgeOutChip() {
        for received in [false, true] {
            var d = SIDLiveActivityDetector(chipCount: 2)
            startVoice(&d, chip: 0); startVoice(&d, chip: 1)
            advance(&d, from: 0, through: 50)
            d.record(chip: 1, offset: 4, value: 0)
            advance(&d, from: 51, through: 900, received: received, healthy: false)
            XCTAssertEqual(d.activeChips, [0, 1])
            advance(&d, from: 901, through: 950)
            XCTAssertEqual(d.activeChips, [0, 1])
        }
    }

    func testLongSchedulingGapDoesNotCountAsInactivity() {
        var d = SIDLiveActivityDetector(chipCount: 2)
        startVoice(&d, chip: 0); startVoice(&d, chip: 1)
        advance(&d, from: 0, through: 50)
        d.record(chip: 1, offset: 4, value: 0)
        d.advance(at: 500, traceReceived: true, traceHealthy: true)
        XCTAssertEqual(d.activeChips, [0, 1])
    }

    func testShortNotesBetweenTicksAreStillEvidence() {
        var d = SIDLiveActivityDetector(chipCount: 2)
        for tick in 0...60 {
            startVoice(&d, chip: 0)
            d.record(chip: 0, offset: 4, value: 0x20)
            d.advance(at: Double(tick)/10, traceReceived: true, traceHealthy: true)
        }
        XCTAssertEqual(d.activeChips, [0])
    }

    func testVolumeSamplePlaybackCountsWithoutGatedVoices() {
        var d = SIDLiveActivityDetector(chipCount: 3)
        for tick in 0...60 {
            for value: UInt8 in [0, 5, 10, 15, 0] { d.record(chip: 1, offset: 24, value: value) }
            d.advance(at: Double(tick)/10, traceReceived: true, traceHealthy: true)
        }
        XCTAssertEqual(d.activeChips, [1])
    }

    func testNoEvidenceRemainsUnknownAndResetStartsOver() {
        var d = SIDLiveActivityDetector(chipCount: 2)
        advance(&d, from: 0, through: 100)
        XCTAssertNil(d.activeChips)
        startVoice(&d, chip: 0)
        advance(&d, from: 101, through: 160)
        XCTAssertEqual(d.activeChips, [0])
        d = SIDLiveActivityDetector(chipCount: 2)
        advance(&d, from: 161, through: 200)
        XCTAssertNil(d.activeChips)
    }

    func testMetadataAndManualOverridesTakePrecedence() {
        let addresses: [UInt16] = [0xD400, 0xD420, 0xD440]
        let file = SIDVisualTopology(configuredAddresses: addresses, tuneAddresses: addresses,
            adaptation: .automatic, liveActiveChips: [0])
        XCTAssertEqual(file.activeChips, [0, 1, 2])
        let live = SIDVisualTopology(configuredAddresses: addresses, tuneAddresses: nil,
            adaptation: .automatic, liveActiveChips: [0, 2])
        XCTAssertEqual(live.activeChips, [0, 2])
        XCTAssertEqual(live.sourceChip(for: 1), 2)
        XCTAssertEqual(SIDVisualTopology(configuredAddresses: addresses, tuneAddresses: nil,
            adaptation: .hardware, liveActiveChips: [0]).activeChips, [0, 1, 2])
        XCTAssertEqual(SIDVisualTopology(configuredAddresses: addresses, tuneAddresses: addresses,
            adaptation: .singleSID, liveActiveChips: [1, 2]).activeChips, [0])
        XCTAssertEqual(SIDVisualizationAdaptation(rawValue: "Auto (SID file)"), .automatic)
    }
}
