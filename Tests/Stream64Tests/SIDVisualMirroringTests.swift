import XCTest
@testable import Stream64

final class SIDVisualMirroringTests: XCTestCase {
    private func channels(activeChip: Int? = 0) -> [SIDVoiceChannel] {
        (0..<6).map { index in
            var channel = SIDVoiceChannel(id: index, chipIndex: index / 3, voiceIndex: index % 3,
                                          bufferSize: 8, noteHistoryLength: 6)
            channel.registers.frequency = UInt16(4000 + index * 1000)
            channel.registers.control = index / 3 == activeChip ? 0x41 : 0x40
            return channel
        }
    }

    func testDetectionWaitsIgnoresBriefPausesAndResumesActualSecondSIDImmediately() {
        var detector = SIDVisualMirrorDetector()
        let filters = Array(repeating: SIDFilterRegisters(modeVolume: 15), count: 2)
        var voices = channels()
        XCTAssertNil(detector.update(channels: voices, filters: filters, at: 0))
        XCTAssertNil(detector.update(channels: voices, filters: filters, at: 4.99))
        XCTAssertEqual(detector.update(channels: voices, filters: filters, at: 5), 0)
        voices[3].registers.control = 0x41
        XCTAssertNil(detector.update(channels: voices, filters: filters, at: 5.01))
        voices[3].registers.control = 0x40
        XCTAssertNil(detector.update(channels: voices, filters: filters, at: 8))
        XCTAssertEqual(detector.update(channels: voices, filters: filters, at: 10.02), 0)
        voices = channels(activeChip: nil)
        XCTAssertNil(detector.update(channels: voices, filters: filters, at: 11), "Never fill silence with stale data")
    }

    func testReverseDirectionMutedVoicesAndDigiActivity() {
        var detector = SIDVisualMirrorDetector()
        let filters = Array(repeating: SIDFilterRegisters(modeVolume: 15), count: 2)
        var voices = channels(activeChip: 1)
        XCTAssertNil(detector.update(channels: voices, filters: filters, at: 0))
        // Frequency/control refreshes without a gate or envelope do not imply use.
        voices[0].registers.frequency = 17000
        XCTAssertEqual(detector.update(channels: voices, filters: filters, at: 5), 1)
        voices[0].digiActivity = 1
        XCTAssertNil(detector.update(channels: voices, filters: filters, at: 5.01))
        voices[0].digiActivity = 0
        voices[0].registers.control = 0x49 // TEST mutes even a gated waveform.
        XCTAssertEqual(detector.update(channels: voices, filters: filters, at: 10.02), 1)
        XCTAssertNil(detector.update(channels: Array(voices.prefix(3)), filters: [filters[0]], at: 11))
        XCTAssertNil(detector.update(channels: voices, filters: filters, at: 12), "Reconfiguration starts a new grace period")
    }

    func testInstrumentViewsMirrorRegistersFiltersAndActivityInBothDirections() {
        let voices = channels()
        let filters = [SIDFilterRegisters(modeVolume: 15), SIDFilterRegisters(modeVolume: 3)]
        var activity = SIDRegisterActivity(chipCount: 2)
        let now = Date()
        activity.record(chipIndex: 0, offset: 0, value: 42, at: now)
        activity.record(chipIndex: 1, offset: 0, value: 99, at: now.addingTimeInterval(-1))
        for source in 0..<2 {
            let destination = 1 - source
            for mode in [SIDVisualizationMode.filterCurve, .adsrKnobs, .registerActivity, .pulseWidth] {
                for enabled in [true, false] {
                    let view = SIDVisualPresentation(channels: voices, filters: filters,
                        rhythm: KAOSRhythmState(), source: source, enabled: enabled, mode: mode,
                        registerActivity: activity)
                    let expected = enabled ? source : destination
                    XCTAssertEqual(view.channels[destination * 3].registers.frequency, voices[expected * 3].registers.frequency)
                    XCTAssertEqual(view.filters[destination].volume, filters[expected].volume)
                    XCTAssertEqual(view.registerActivity.values[destination], activity.values[expected])
                    XCTAssertEqual(view.registerActivity.lastWrite[destination], activity.lastWrite[expected])
                    XCTAssertEqual(view.registerActivity.lastChange[destination], activity.lastChange[expected])
                }
            }
        }
        XCTAssertEqual(activity.values[0][0], 42)
        XCTAssertEqual(activity.values[1][0], 99)
    }

    func testMirroredCopiesRetainDestinationIdentityAndNeverAlterDiagnosticsOrAudioState() {
        var voices = channels()
        voices[0].push(sample: 0.75, envelope: 0.8)
        voices[0].pushNoteHistory()
        let filters = [SIDFilterRegisters(modeVolume: 15), SIDFilterRegisters(modeVolume: 0)]
        var rhythm = KAOSRhythmState()
        rhythm.voiceLevels = [0.8, 0.5, 0.3, 0, 0, 0]
        rhythm.activeVoiceMask = 7
        let mirrored = SIDVisualPresentation(channels: voices, filters: filters, rhythm: rhythm,
            source: 0, enabled: true, mode: .sidShowcase)
        for index in 3..<6 {
            XCTAssertEqual(mirrored.channels[index].id, index)
            XCTAssertEqual(mirrored.channels[index].chipIndex, 1)
            XCTAssertEqual(mirrored.channels[index].voiceIndex, index - 3)
            XCTAssertEqual(mirrored.channels[index].registers.frequency, voices[index - 3].registers.frequency)
            XCTAssertEqual(mirrored.channels[index].orderedSamples, voices[index - 3].orderedSamples)
        }
        XCTAssertEqual(mirrored.filters[1].volume, 15)
        XCTAssertEqual(mirrored.rhythm.activeVoiceMask, 63)
        XCTAssertEqual(mirrored.rhythm.voiceLevels[3], 0.8)
        XCTAssertEqual(voices[3].registers.control, 0x40)
        XCTAssertEqual(filters[1].volume, 0)
        for mode in [SIDVisualizationMode.controlBits, .dashboard] {
            let diagnostic = SIDVisualPresentation(channels: voices, filters: filters, rhythm: rhythm,
                source: 0, enabled: true, mode: mode)
            XCTAssertEqual(diagnostic.channels[3].registers.frequency, voices[3].registers.frequency)
            XCTAssertEqual(diagnostic.filters[1].volume, 0)
            XCTAssertEqual(diagnostic.rhythm.activeVoiceMask, 7)
        }
        let disabled = SIDVisualPresentation(channels: voices, filters: filters, rhythm: rhythm,
            source: 0, enabled: false, mode: .sidShowcase)
        XCTAssertEqual(disabled.channels[3].registers.frequency, voices[3].registers.frequency)
    }
}
