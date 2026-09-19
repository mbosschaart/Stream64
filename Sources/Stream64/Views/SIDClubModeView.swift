import SwiftUI

/// A shuffled deck guarantees every individual visualization gets a turn.
/// Club Mode never enters its own deck, including after new modes are added.
struct SIDClubModeSequence {
    struct Cue: Equatable {
        let mode: SIDVisualizationMode
        let duration: TimeInterval
        var isBurst = false
        var isReplay = false
    }

    static let durationRange: ClosedRange<TimeInterval> = 0.5...3
    private var remaining: [SIDVisualizationMode] = []
    static let burstDuration: TimeInterval = 0.2
    static let normalScenesBetweenBursts = 4...8
    private var previous: SIDVisualizationMode?
    private var burstReplay: [SIDVisualizationMode] = []
    private var normalScenesLeft: Int?

    mutating func next<R: RandomNumberGenerator>(using random: inout R) -> Cue {
        if !burstReplay.isEmpty {
            return Cue(mode: burstReplay.removeFirst(), duration: Self.burstDuration,
                       isBurst: true, isReplay: true)
        }
        if normalScenesLeft == nil {
            normalScenesLeft = .random(in: Self.normalScenesBetweenBursts, using: &random)
        }
        if normalScenesLeft == 0, let a = previous {
            let b = drawMode(using: &random)
            // Five cuts: A → B → A → B → A → B. The first B consumes
            // one deck entry; the four return visits do not skip other scenes.
            burstReplay = [a, b, a, b]
            normalScenesLeft = .random(in: Self.normalScenesBetweenBursts, using: &random)
            return Cue(mode: b, duration: Self.burstDuration, isBurst: true)
        }
        normalScenesLeft = (normalScenesLeft ?? 1) - 1
        return Cue(mode: drawMode(using: &random),
                   duration: .random(in: Self.durationRange, using: &random))
    }

    private mutating func drawMode<R: RandomNumberGenerator>(using random: inout R) -> SIDVisualizationMode {
        if remaining.isEmpty {
            remaining = SIDVisualizationMode.individualModes.shuffled(using: &random)
            // popLast is the next cue. Avoid a repeat across deck boundaries
            // without removing any visualization from the next complete round.
            if remaining.count > 1, remaining.last == previous {
                remaining.swapAt(0, remaining.count - 1)
            }
        }
        let mode = remaining.removeLast()
        previous = mode
        return mode
    }
}

/// Driven by the existing shared-engine tick: no extra timer, audio listener
/// or debug lease. Hide pauses the countdown; close stops it; show resumes it.
@MainActor
final class SIDClubModeController: ObservableObject {
    @Published private(set) var currentMode: SIDVisualizationMode
    private(set) var currentDuration: TimeInterval
    private(set) var isRunning = false
    private var isVisible = false
    private var deadline: TimeInterval?
    private var remainingDuration: TimeInterval
    private var sequence = SIDClubModeSequence()
    private var random = SystemRandomNumberGenerator()

    init() {
        var sequence = SIDClubModeSequence()
        var random = SystemRandomNumberGenerator()
        let cue = sequence.next(using: &random)
        currentMode = cue.mode
        currentDuration = cue.duration
        remainingDuration = cue.duration
        self.sequence = sequence
        self.random = random
    }

    func start(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !isRunning else { return }
        isRunning = true
        isVisible = true
        deadline = now + remainingDuration
    }

    func stop() {
        isRunning = false
        isVisible = false
        deadline = nil
        remainingDuration = currentDuration
    }

    func setVisible(_ visible: Bool, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isRunning, visible != isVisible else { return }
        isVisible = visible
        if visible {
            deadline = now + remainingDuration
        } else {
            remainingDuration = max(0, (deadline ?? now) - now)
            deadline = nil
        }
    }

    func advance(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isRunning, isVisible, let deadline, now >= deadline else { return }
        let cue = sequence.next(using: &random)
        currentMode = cue.mode
        currentDuration = cue.duration
        remainingDuration = cue.duration
        // Late ticks cut once, then give the new effect a full slot. No
        // rapid catch-up sequence after a busy main thread or system sleep.
        self.deadline = now + cue.duration
    }
}

/// The outer window remains Club Mode for menus and saved layouts. Only its
/// visible child changes, with hard VJ-style cuts and one mounted effect.
struct SIDClubModeView: View {
    let model: SIDOscilloscopeViewModel
    @ObservedObject var controller: SIDClubModeController

    var body: some View {
        SIDVisualizationContent(model: model, mode: controller.currentMode)
            .id(controller.currentMode)
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .accessibilityLabel("Club Mode: \(controller.currentMode.displayName)")
    }
}
