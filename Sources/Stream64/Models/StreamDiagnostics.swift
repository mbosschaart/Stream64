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
    }

    struct Audio: Equatable {
        var packetsPerSecond: Double = 0
        var rejectedPacketsPerSecond: Double = 0
        var bufferedMilliseconds: Int = 0
        var underrunsPerSecond: Double = 0
        var droppedFramesPerSecond: Double = 0
    }

    struct Renderer: Equatable {
        var presentFPS: Double = 0
        var queuedFrames: Int = 0
        var droppedFramesPerSecond: Double = 0
        var gpuBehind: Bool = false
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

    var isDegraded: Bool {
        renderer.gpuBehind
            || renderer.queuedFrames >= 2
            || video.rejectedPacketsPerSecond > 0
            || audio.underrunsPerSecond > 0
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

    func publish(_ snapshot: StreamDiagnosticsSnapshot) {
        self.snapshot = snapshot
    }
}

struct VideoReceiverDiagnostics: Equatable {
    var packets: Int = 0
    var rejectedPackets: Int = 0
    var completedFrames: Int = 0
    var frameHeight: Int = 0
}

struct AudioReceiverDiagnostics: Equatable {
    var packets: Int = 0
    var rejectedPackets: Int = 0
    var bufferedMilliseconds: Int = 0
    var underruns: Int = 0
    var droppedFrames: Int = 0
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
