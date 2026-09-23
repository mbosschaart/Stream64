import Foundation

/// One CSV row per second of stream health, for diagnosing Wi-Fi playback.
/// Files go to ~/Library/Logs/Stream64/.
@MainActor
final class StreamHealthLog {
    let url: URL
    private let handle: FileHandle
    private let startedAt = Date()

    static let header = [
        "time", "elapsed_s", "health",
        "video_mbps", "video_pps", "video_lost", "video_reordered",
        "video_rejected", "video_max_gap_ms",
        "frames_in", "frames_patched", "frames_dropped",
        "audio_mbps", "audio_pps", "audio_lost", "audio_max_gap_ms",
        "audio_buffer_ms", "audio_underruns", "audio_overflow_frames",
        "buffering", "playout_frames", "playout_target",
        "playout_underruns", "playout_overflow",
        "present_fps", "render_queued", "render_dropped", "gpu_behind",
        "debug_mbps", "total_mbps",
    ].joined(separator: ",")

    init(deviceName: String) throws {
        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Stream64", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let stamp = Self.fileStamp.string(from: Date())
        let safeName = deviceName.components(
            separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        url = directory.appendingPathComponent(
            "stream-\(safeName.isEmpty ? "device" : safeName)-\(stamp).csv")
        FileManager.default.createFile(
            atPath: url.path, contents: Data((Self.header + "\n").utf8))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    func append(_ s: StreamDiagnosticsSnapshot) throws {
        func f(_ value: Double, _ digits: Int = 1) -> String {
            String(format: "%.\(digits)f", value)
        }
        let now = Date()
        let row: [String] = [
            Self.rowStamp.string(from: now),
            f(now.timeIntervalSince(startedAt)),
            s.isDegraded ? "degraded" : "healthy",
            f(s.video.megabitsPerSecond, 2), f(s.video.packetsPerSecond, 0),
            f(s.video.lostPacketsPerSecond, 0),
            f(s.video.reorderedPacketsPerSecond, 0),
            f(s.video.rejectedPacketsPerSecond, 0),
            f(s.video.maxArrivalGapMilliseconds),
            f(s.video.framesPerSecond), f(s.buffering.concealedFramesPerSecond, 0),
            f(s.video.droppedFramesPerSecond, 0),
            f(s.audio.megabitsPerSecond, 2), f(s.audio.packetsPerSecond, 0),
            f(s.audio.lostPacketsPerSecond, 0),
            f(s.audio.maxArrivalGapMilliseconds),
            String(s.audio.bufferedMilliseconds),
            f(s.audio.underrunsPerSecond, 0), f(s.audio.droppedFramesPerSecond, 0),
            s.buffering.enabled ? "1" : "0",
            String(s.buffering.bufferedFrames), String(s.buffering.targetFrames),
            f(s.buffering.underrunsPerSecond, 0),
            f(s.buffering.overflowDropsPerSecond, 0),
            f(s.renderer.presentFPS), String(s.renderer.queuedFrames),
            f(s.renderer.droppedFramesPerSecond, 0),
            s.renderer.gpuBehind ? "1" : "0",
            f(s.debug.megabitsPerSecond, 2), f(s.totalMegabitsPerSecond, 2),
        ]
        try handle.write(contentsOf: Data((row.joined(separator: ",") + "\n").utf8))
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let rowStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
