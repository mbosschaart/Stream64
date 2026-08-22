import XCTest
@testable import Stream64

final class StreamDiagnosticsTests: XCTestCase {
    func testHealthIsDegradedForPipelinePressureOrLoss() {
        XCTAssertFalse(StreamDiagnosticsSnapshot().isDegraded)

        var snapshot = StreamDiagnosticsSnapshot()
        snapshot.renderer.gpuBehind = true
        XCTAssertTrue(snapshot.isDegraded)

        snapshot.renderer.gpuBehind = false
        snapshot.audio.underrunsPerSecond = 1
        XCTAssertTrue(snapshot.isDegraded)

        snapshot.audio.underrunsPerSecond = 0
        snapshot.video.rejectedPacketsPerSecond = 1
        XCTAssertTrue(snapshot.isDegraded)
    }

    func testVideoReceiverDiagnosticsCountAcceptedAndRejectedPackets() {
        let receiver = VideoReceiver()
        receiver.ingest(Data(repeating: 0, count: 10))

        var packet = Data(repeating: 0, count: 12 + VideoReceiver.width / 2)
        packet[6] = 0x80
        packet[7] = 0x01
        packet[8] = 1
        packet[9] = 4
        receiver.ingest(packet)

        let snapshot = receiver.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.packets, 1)
        XCTAssertEqual(snapshot.rejectedPackets, 1)
        XCTAssertEqual(snapshot.completedFrames, 0)
    }
}
