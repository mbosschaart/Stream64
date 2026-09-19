import XCTest
@testable import Stream64

final class SIDClubModeTests: XCTestCase {
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64 = 42
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testShuffleCoversEveryEffectAndNeverRepeatsAtRoundBoundary() {
        var sequence = SIDClubModeSequence()
        var random = SeededRandom()
        let expected = Set(SIDVisualizationMode.individualModes)
        XCTAssertFalse(SIDVisualizationMode.activeModes.contains(.kaos))
        XCTAssertFalse(expected.contains(.kaos))
        XCTAssertTrue(SIDVisualizationMode.activeModes.contains(.clubMode))
        var last: SIDVisualizationMode?
        var durations = Set<TimeInterval>()
        for _ in 0..<20 {
            var round = Set<SIDVisualizationMode>()
            for _ in 0..<expected.count {
                var cue = sequence.next(using: &random)
                while cue.isReplay { cue = sequence.next(using: &random) }
                XCTAssertNotEqual(cue.mode, .clubMode)
                XCTAssertNotEqual(cue.mode, last)
                XCTAssertTrue(cue.isBurst ? cue.duration == 0.2 : (0.5...3).contains(cue.duration))
                XCTAssertTrue(round.insert(cue.mode).inserted)
                last = cue.mode
                durations.insert(cue.duration)
            }
            XCTAssertEqual(round, expected)
        }
        XCTAssertGreaterThan(durations.count, 20, "Each scene needs a fresh random duration")
    }

    func testBurstsAlternateExactlyFiveTimesAndResumeNormalRotation() {
        var sequence = SIDClubModeSequence()
        var random = SeededRandom()
        var previous: SIDVisualizationMode?
        var normalCount = 0
        var bursts = 0
        while bursts < 30 {
            let cue = sequence.next(using: &random)
            if !cue.isBurst {
                XCTAssertTrue((0.5...3).contains(cue.duration))
                XCTAssertNotEqual(cue.mode, previous)
                normalCount += 1
                previous = cue.mode
                continue
            }
            XCTAssertTrue((4...8).contains(normalCount))
            let a = previous!
            let b = cue.mode
            XCTAssertNotEqual(a, b)
            XCTAssertEqual(cue.duration, 0.2)
            XCTAssertFalse(cue.isReplay)
            for expected in [a, b, a, b] {
                let swap = sequence.next(using: &random)
                XCTAssertEqual(swap.mode, expected)
                XCTAssertEqual(swap.duration, 0.2)
                XCTAssertTrue(swap.isBurst)
                XCTAssertTrue(swap.isReplay)
            }
            previous = b
            normalCount = 0
            bursts += 1
        }
    }

    @MainActor
    func testBurstCountdownPausesAndNeverCatchesUpMultipleSwaps() {
        let club = SIDClubModeController()
        var now: TimeInterval = 0
        club.start(at: now)
        for _ in 0..<10 {
            now += club.currentDuration + 0.001
            club.advance(at: now)
            if club.currentDuration == 0.2 { break }
        }
        XCTAssertEqual(club.currentDuration, 0.2)
        let b = club.currentMode
        club.setVisible(false, at: now + 0.1)
        club.advance(at: now + 100)
        XCTAssertEqual(club.currentMode, b)
        club.setVisible(true, at: now + 100)
        club.advance(at: now + 100.09)
        XCTAssertEqual(club.currentMode, b)
        club.advance(at: now + 100.11)
        let a = club.currentMode
        XCTAssertNotEqual(a, b)
        club.advance(at: now + 200)
        XCTAssertEqual(club.currentMode, b, "A delayed tick makes just one swap")
        club.stop()
        club.advance(at: now + 300)
        XCTAssertEqual(club.currentMode, b)
    }

    @MainActor
    func testCountdownCutsAtDeadlinePausesWhenHiddenAndStopsOnClose() {
        let club = SIDClubModeController()
        let first = club.currentMode
        let duration = club.currentDuration
        club.start(at: 10)
        club.advance(at: 10 + duration / 2 - 0.01)
        XCTAssertEqual(club.currentMode, first)
        club.setVisible(false, at: 10 + duration / 2)
        club.advance(at: 100)
        XCTAssertEqual(club.currentMode, first)
        club.setVisible(true, at: 100)
        club.advance(at: 100 + duration / 2 - 0.01)
        XCTAssertEqual(club.currentMode, first)
        club.advance(at: 100 + duration / 2 + 0.01)
        XCTAssertNotEqual(club.currentMode, first)
        let second = club.currentMode
        club.stop()
        club.advance(at: 1000)
        XCTAssertEqual(club.currentMode, second)
        XCTAssertFalse(club.isRunning)
    }

    @MainActor
    func testLateTickMakesOneCutAndGivesNewSceneItsFullDuration() {
        let club = SIDClubModeController()
        club.start(at: 0)
        let first = club.currentMode
        club.advance(at: 1000)
        XCTAssertNotEqual(club.currentMode, first)
        let second = club.currentMode
        club.advance(at: 1000 + club.currentDuration - 0.01)
        XCTAssertEqual(club.currentMode, second)
    }

    func testClubNeedsKeepAllSharedAnalysisWarmAcrossCuts() {
        let needs = SIDEngineNeeds(mode: .clubMode)
        for mode in SIDVisualizationMode.individualModes {
            XCTAssertEqual(needs.union(SIDEngineNeeds(mode: mode)), needs,
                           "Club Mode must already supply \(mode.displayName)")
        }
        XCTAssertTrue(needs.needsRegisterWrites)
        XCTAssertTrue(needs.needsAudioTap)
        XCTAssertTrue(needs.usesSpectrogramHistory)
        XCTAssertTrue(needs.needsKAOSRhythm)
    }

    func testDisplayNamesPreserveLegacySavedModesAndClubIdentity() throws {
        let legacyNames = ["Alien Flower", "Blackhole", "Arrow Vector Field", "Sea", "Club Mode"]
        let displayNames = ["SID Bloom", "Pulse Vortex", "Vector Flow", "Neon Tide", "Club Mode"]
        let entries = legacyNames.map {
            SIDWindowLayoutEntry(mode: $0, frame: CGRect(x: 0, y: 0, width: 760, height: 460))
        }
        let restored = try JSONDecoder().decode([SIDWindowLayoutEntry].self,
            from: JSONEncoder().encode(entries))
        XCTAssertEqual(restored.compactMap { SIDVisualizationMode(rawValue: $0.mode)?.displayName }, displayNames)
        XCTAssertEqual(SIDVisualizationMode.clubMode.rawValue, "Club Mode")
    }
}
