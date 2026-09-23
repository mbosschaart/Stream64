import Foundation
import Combine

/// A deliberately low-frequency view of one stream's transport and display
/// pipeline. It is published at most once per second by `DeviceSession`;
/// receive/render hot paths only maintain bounded counters.
struct StreamDiagnosticsSnapshot: Equatable {
    struct Video: Equatable {
        var packetsPerSecond: Double = 0
        var framesPerSecond: Double = 0
        var rejectedPacketsPerSecond: Double = 0
        var frameHeight: Int = 0
        var megabitsPerSecond: Double = 0
        var lostPacketsPerSecond: Double = 0
        var reorderedPacketsPerSecond: Double = 0
        var droppedFramesPerSecond: Double = 0
        var maxArrivalGapMilliseconds: Double = 0

        /// Share of datagrams that never arrived, 0...1.
        var lossRatio: Double {
            let expected = packetsPerSecond + lostPacketsPerSecond
            return expected > 0 ? lostPacketsPerSecond / expected : 0
        }
    }

    struct Audio: Equatable {
        var packetsPerSecond: Double = 0
        var rejectedPacketsPerSecond: Double = 0
        var bufferedMilliseconds: Int = 0
        var underrunsPerSecond: Double = 0
        var droppedFramesPerSecond: Double = 0
        var megabitsPerSecond: Double = 0
        var lostPacketsPerSecond: Double = 0
        var maxArrivalGapMilliseconds: Double = 0
    }

    /// The U64 debug (bus trace) stream shares the same link as video and
    /// audio, and at roughly 32 Mbit/s it can use more than both combined.
    struct Debug: Equatable {
        var megabitsPerSecond: Double = 0
    }

    struct Renderer: Equatable {
        var presentFPS: Double = 0
        var queuedFrames: Int = 0
        var droppedFramesPerSecond: Double = 0
        var gpuBehind: Bool = false
    }

    /// Wi-Fi playout buffer. `enabled` is false when streams play on arrival.
    struct Buffering: Equatable {
        var enabled: Bool = false
        var targetFrames: Int = 0
        var bufferedFrames: Int = 0
        var underrunsPerSecond: Double = 0
        var concealedFramesPerSecond: Double = 0
        var overflowDropsPerSecond: Double = 0
    }

    struct Recording: Equatable {
        var active: Bool = false
        var filtered: Bool = false
        var queuedVideoFrames: Int = 0
        var droppedVideoFramesPerSecond: Double = 0
        var droppedAudioPacketsPerSecond: Double = 0
    }

    var video = Video()
    var audio = Audio()
    var renderer = Renderer()
    var recording = Recording()
    var buffering = Buffering()
    var debug = Debug()

    var totalMegabitsPerSecond: Double {
        video.megabitsPerSecond + audio.megabitsPerSecond + debug.megabitsPerSecond
    }

    /// With buffering on, late or reordered packets are expected and absorbed
    /// by the buffer, so only a drained buffer counts as degraded.
    var isDegraded: Bool {
        if renderer.gpuBehind
            || renderer.queuedFrames >= 2
            || audio.underrunsPerSecond > 0 {
            return true
        }
        if buffering.enabled {
            return buffering.underrunsPerSecond > 0
        }
        return video.rejectedPacketsPerSecond > 0
    }

    var healthLabel: String {
        isDegraded ? "Degraded" : "Healthy"
    }
}

/// Kept separate from `DeviceSession.objectWillChange`: observing the
/// once-per-second diagnostics must never recreate the Metal video host.
@MainActor
final class StreamDiagnostics: ObservableObject {
    @Published private(set) var snapshot = StreamDiagnosticsSnapshot()
    /// File the per-second stream log is being written to, if any.
    @Published var logURL: URL?

    func publish(_ snapshot: StreamDiagnosticsSnapshot) {
        self.snapshot = snapshot
    }
}

/// How this Mac reaches the device, for the toolbar's Wi-Fi buffering
/// indicator. Separate from `DeviceSession.objectWillChange` for the same
/// reason as `StreamDiagnostics`.
@MainActor
final class StreamRouteStatus: ObservableObject {
    @Published private(set) var overWiFi = false
    @Published private(set) var interfaceName: String?

    /// Returns true when the medium changed.
    @discardableResult
    func update(overWiFi: Bool, interfaceName: String?) -> Bool {
        let changed = overWiFi != self.overWiFi
        if changed { self.overWiFi = overWiFi }
        if interfaceName != self.interfaceName { self.interfaceName = interfaceName }
        return changed
    }
}

struct VideoReceiverDiagnostics: Equatable {
    var packets: Int = 0
    var rejectedPackets: Int = 0
    var completedFrames: Int = 0
    var frameHeight: Int = 0
    var concealedFrames: Int = 0
    var playout: VideoPlayoutBuffer.Diagnostics?
    var bytes: Int = 0
    var lostPackets: Int = 0
    var reorderedPackets: Int = 0
    /// Frames that never reached the display (loss beyond concealment).
    var droppedFrames: Int = 0
    /// Not cumulative: the longest gap since the previous snapshot.
    var maxArrivalGapMilliseconds: Double = 0
}

struct AudioReceiverDiagnostics: Equatable {
    var packets: Int = 0
    var rejectedPackets: Int = 0
    var bufferedMilliseconds: Int = 0
    var underruns: Int = 0
    var droppedFrames: Int = 0
    var bytes: Int = 0
    var lostPackets: Int = 0
    /// Not cumulative: the longest gap since the previous snapshot.
    var maxArrivalGapMilliseconds: Double = 0
}

struct MetalRendererDiagnostics: Equatable {
    var presentFPS: Double = 0
    var queuedFrames: Int = 0
    var droppedFrames: Int = 0
    var gpuBehind: Bool = false
}

struct RecordingDiagnostics: Equatable {
    var queuedVideoFrames: Int = 0
    var droppedVideoFrames: Int = 0
    var droppedAudioPackets: Int = 0
}
