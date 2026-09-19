import XCTest
@testable import Stream64

final class SIDVisualMirroringTests: XCTestCase {
    private let addresses: [UInt16] = [0xD400, 0xD420, 0xD440]
    private let instruments: [SIDVisualizationMode] = [
        .oscilloscope, .envelope, .mixerConsole, .pianoRoll, .pianoKeyboard,
        .voiceLineup, .vuMeterBank, .registerActivity, .adsrKnobs, .pulseWidth,
        .controlBits, .dashboard, .filterCurve
    ]

    private func presentation(chips: Int, tuneChips: Int?, mode: SIDVisualizationMode,
                              adaptation: SIDVisualizationAdaptation = .automatic) -> SIDVisualPresentation {
        let channels = (0..<(chips * 3)).map { index in
            var channel = SIDVoiceChannel(id: index, chipIndex: index / 3, voiceIndex: index % 3,
                                          bufferSize: 8, noteHistoryLength: 6)
            channel.registers.frequency = UInt16(4000 + index * 1000)
            channel.registers.control = 0 // Silence must never change tune topology.
            channel.push(sample: Float(index) / 10, envelope: 0.8)
            return channel
        }
        let filters = (0..<chips).map { SIDFilterRegisters(modeVolume: UInt8(15 - $0)) }
        var rhythm = KAOSRhythmState()
        rhythm.voiceLevels = (0..<(chips * 3)).map { Float($0) / 10 }
        rhythm.activeVoiceMask = 7
        var activity = SIDRegisterActivity(chipCount: chips)
        for chip in 0..<chips {
            activity.record(chipIndex: chip, offset: 0, value: UInt8(42 + chip), at: Date(timeIntervalSince1970: Double(chip)))
        }
        return SIDVisualPresentation(channels: channels, filters: filters, rhythm: rhythm,
            topology: SIDVisualTopology(configuredAddresses: Array(addresses.prefix(chips)),
                tuneAddresses: tuneChips.map { Array(addresses.prefix($0)) }, adaptation: adaptation),
            mode: mode, registerActivity: activity)
    }

    func testSingleSIDInstrumentsHideUnusedChipsIncludingFiltersAndRegisters() {
        for chips in [2, 3] {
            for mode in instruments {
                let view = presentation(chips: chips, tuneChips: 1, mode: mode)
                XCTAssertEqual(view.chipCount, 1, mode.rawValue)
                XCTAssertEqual(view.channels.map(\.id), [0, 1, 2])
                XCTAssertEqual(view.filters.count, 1)
                XCTAssertEqual(view.registerActivity.values.count, 1)
                XCTAssertEqual(view.registerActivity.values[0][0], 42)
                XCTAssertEqual(view.displayedChipIndices, [0])
            }
        }
    }

    func testAbstractViewsMirrorAllUnusedVoicesRetainingIdentity() {
        for mode in SIDVisualizationMode.individualModes where !instruments.contains(mode) {
            let view = presentation(chips: 3, tuneChips: 1, mode: mode)
            XCTAssertEqual(view.chipCount, 3)
            XCTAssertEqual(view.channels.count, 9)
            for index in 3..<9 {
                XCTAssertEqual(view.channels[index].id, index)
                XCTAssertEqual(view.channels[index].chipIndex, index / 3)
                XCTAssertEqual(view.channels[index].registers.frequency, view.channels[index % 3].registers.frequency)
                XCTAssertEqual(view.channels[index].orderedSamples, view.channels[index % 3].orderedSamples)
                XCTAssertEqual(view.rhythm.voiceLevels[index], view.rhythm.voiceLevels[index % 3])
            }
            XCTAssertEqual(view.rhythm.activeVoiceMask, 511)
            XCTAssertEqual(view.filters.map(\.volume), [15, 15, 15])
            XCTAssertEqual(view.registerActivity.values[1][0], 43, "Raw activity is not fabricated")
        }
    }

    func testMultiSIDAndUnknownNeverCollapseDuringSilence() {
        for mode in instruments {
            XCTAssertEqual(presentation(chips: 3, tuneChips: 2, mode: mode).channels.count, 6)
            XCTAssertEqual(presentation(chips: 3, tuneChips: 3, mode: mode).channels.count, 9)
            XCTAssertEqual(presentation(chips: 2, tuneChips: nil, mode: mode).channels.count, 6)
            XCTAssertEqual(presentation(chips: 2, tuneChips: 1, mode: mode, adaptation: .hardware).channels.count, 6)
            XCTAssertEqual(presentation(chips: 2, tuneChips: nil, mode: mode, adaptation: .singleSID).channels.count, 3)
        }
        let two = presentation(chips: 3, tuneChips: 2, mode: .sidShowcase)
        XCTAssertNotEqual(two.channels[3].registers.frequency, two.channels[0].registers.frequency)
        XCTAssertEqual(two.channels[6].registers.frequency, two.channels[0].registers.frequency)
        let unknown = presentation(chips: 2, tuneChips: nil, mode: .sidShowcase)
        XCTAssertNotEqual(unknown.channels[3].registers.frequency, unknown.channels[0].registers.frequency)
    }

    func testPlaybackMetadataInvalidationAndLateCompletion() {
        var playback = SIDPlaybackMetadata()
        XCTAssertNil(playback.addresses)
        let first = playback.beginPlayback()
        playback.didStart(addresses: [0xD400], generation: first)
        XCTAssertEqual(playback.addresses, [0xD400])
        let second = playback.beginPlayback()
        XCTAssertNil(playback.addresses)
        playback.didStart(addresses: addresses, generation: first)
        XCTAssertNil(playback.addresses, "A stale upload completion must not override a reset or a newer tune")
        playback.didStart(addresses: addresses, generation: second)
        XCTAssertEqual(playback.addresses?.count, 3)
        playback.beginPlayback()
        XCTAssertNil(playback.addresses)
    }

    func testTopologyUsesAddressesAndSafelyHandlesMissingHardware() {
        let topology = SIDVisualTopology(configuredAddresses: addresses, tuneAddresses: [0xD400, 0xD440], adaptation: .automatic)
        XCTAssertEqual(topology.activeChips, [0, 2])
        XCTAssertEqual(topology.sourceChip(for: 1), 2)
        let missing = SIDVisualTopology(configuredAddresses: [0xD400], tuneAddresses: addresses, adaptation: .automatic)
        XCTAssertEqual(missing.activeChips, [0])
    }
}
