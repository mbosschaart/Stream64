import Foundation

/// Optional fixed-delay playout for the display path.
///
/// Wi-Fi delivers the Ultimate's frames in bursts separated by gaps. Shown on
/// arrival, a burst collapses in the renderer (only the newest frame of the
/// burst is drawn) and a gap freezes the picture, which reads as choppy
/// motion. With buffering on, complete frames queue here and a steady clock
/// releases one per video-standard tick, trading latency for smoothness.
///
/// The playout clock trims its rate by at most ±2% to hold the queue near the
/// target depth. That absorbs the small clock difference between the C64 and
/// this Mac without periodic skips or repeats.
///
/// `@unchecked Sendable` because all mutable state is confined to `queue`.
final class VideoPlayoutBuffer: @unchecked Sendable {
    /// Real C64 field rates. The trim loop corrects any residual mismatch.
    static let palFrameRate = 50.1245
    static let ntscFrameRate = 59.8261
    private static let maximumRateTrim = 0.02

    private let queue = DispatchQueue(
        label: "video-playout", qos: .userInteractive)
    private let output: (Data) -> Void
    private var timer: DispatchSourceTimer?
    private var frames: [Data] = []
    private var targetFrames: Int
    private var frameRate = palFrameRate
    private var nextDeadline: UInt64 = 0

    // Cumulative diagnostics, sampled once per second.
    private var underrunCount = 0
    private var overflowDropCount = 0

    struct Diagnostics: Equatable {
        var bufferedFrames = 0
        var targetFrames = 0
        var underruns = 0
        var overflowDrops = 0
    }

    /// - Parameter output: called on the playout queue, one frame per tick.
    init(targetSeconds: Double, output: @escaping (Data) -> Void) {
        self.output = output
        targetFrames = Self.frames(for: targetSeconds, rate: Self.palFrameRate)
    }

    deinit {
        timer?.cancel()
    }

    private static func frames(for seconds: Double, rate: Double) -> Int {
        max(1, Int((seconds * rate).rounded()))
    }

    var targetSeconds: Double {
        get { queue.sync { Double(targetFrames) / frameRate } }
        set {
            queue.async { [weak self] in
                guard let self else { return }
                self.retarget(Self.frames(for: newValue, rate: self.frameRate))
            }
        }
    }

    /// A live depth change must move video by the same amount at once, the
    /// way `AudioReceiver.bufferSeconds` does; the ±2% trim alone would take
    /// minutes and leave picture and sound out of step meanwhile.
    private func retarget(_ newTarget: Int) {
        let previous = targetFrames
        targetFrames = newTarget
        if newTarget > previous {
            // Hold the picture until the deeper buffer fills (audio goes
            // silent for the same span); `enqueueOnQueue` restarts the clock.
            if frames.count < newTarget { stopClock() }
        } else if frames.count > newTarget {
            // Skip ahead to the new depth, as audio trims its backlog.
            frames.removeFirst(frames.count - newTarget)
        }
        // A shallower target may already be met while still priming.
        if timer == nil, frames.count >= targetFrames {
            startClock()
        }
    }

    func enqueue(_ frame: Data) {
        queue.async { [weak self] in self?.enqueueOnQueue(frame) }
    }

    /// Drops queued frames and stops the clock; the next frames re-prime.
    func flush() {
        queue.async { [weak self] in self?.flushOnQueue() }
    }

    func diagnosticsSnapshot() -> Diagnostics {
        queue.sync {
            Diagnostics(
                bufferedFrames: frames.count,
                targetFrames: targetFrames,
                underruns: underrunCount,
                overflowDrops: overflowDropCount)
        }
    }

    /// Test hook: blocks until previously enqueued work has run.
    func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - Queue-confined

    private func enqueueOnQueue(_ frame: Data) {
        let height = frame.count / VideoReceiver.width
        let rate = height <= VideoReceiver.ntscHeight
            ? Self.ntscFrameRate : Self.palFrameRate
        if rate != frameRate {
            // Keep the configured delay in seconds across a PAL/NTSC switch.
            let seconds = Double(targetFrames) / frameRate
            frameRate = rate
            targetFrames = Self.frames(for: seconds, rate: rate)
        }

        frames.append(frame)
        // A burst after a long stall, or a C64 clock faster than the trim
        // can follow, must not grow latency without bound.
        let limit = targetFrames * 2 + 4
        if frames.count > limit {
            let excess = frames.count - targetFrames
            frames.removeFirst(excess)
            overflowDropCount += excess
        }

        if timer == nil, frames.count >= targetFrames {
            startClock()
        }
    }

    private func flushOnQueue() {
        stopClock()
        frames.removeAll(keepingCapacity: true)
    }

    private func startClock() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        nextDeadline = DispatchTime.now().uptimeNanoseconds
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: nextDeadline),
            repeating: .never,
            leeway: .microseconds(250))
        timer.resume()
    }

    private func stopClock() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard !frames.isEmpty else {
            // The gap outlasted the buffer. Rebuild the full depth before
            // resuming so one long dropout does not become many short ones.
            underrunCount += 1
            stopClock()
            return
        }
        output(frames.removeFirst())

        // Positive error = too much queued: play slightly faster.
        let error = Double(frames.count - targetFrames) / Double(targetFrames)
        let trim = min(Self.maximumRateTrim,
                       max(-Self.maximumRateTrim, error * 2 * Self.maximumRateTrim))
        let interval = UInt64(1_000_000_000 / (frameRate * (1 + trim)))
        nextDeadline += interval
        let now = DispatchTime.now().uptimeNanoseconds
        if nextDeadline < now {
            // Woken late (sleep, heavy load): re-anchor rather than firing a
            // catch-up burst.
            nextDeadline = now + interval
        }
        timer?.schedule(
            deadline: DispatchTime(uptimeNanoseconds: nextDeadline),
            repeating: .never,
            leeway: .microseconds(250))
    }
}
