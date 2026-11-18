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

final class NetworkBufferingTests: XCTestCase {
    private func packet(
        sequence: UInt16, frame: UInt16, startLine: Int, lines: Int,
        value: UInt8, last: Bool
    ) -> Data {
        var data = Data(repeating: 0, count: 12 + 384 * lines / 2)
        data[0] = UInt8(sequence & 0xFF)
        data[1] = UInt8(sequence >> 8)
        data[2] = UInt8(frame & 0xFF)
        data[3] = UInt8(frame >> 8)
        let lineField = UInt16(startLine) | (last ? 0x8000 : 0)
        data[4] = UInt8(lineField & 0xFF)
        data[5] = UInt8(lineField >> 8)
        data[6] = 0x80
        data[7] = 0x01
        data[8] = UInt8(lines)
        data[9] = 4
        for index in 12..<data.count { data[index] = value | (value << 4) }
        return data
    }

    /// Feeds one PAL frame as 68 packets of 4 lines, skipping `skipping`.
    private func ingestFrame(
        _ receiver: VideoReceiver, id: UInt16, value: UInt8,
        skipping: Set<Int> = []
    ) {
        for index in 0..<68 where !skipping.contains(index) {
            receiver.ingest(packet(
                sequence: id &* 68 &+ UInt16(index), frame: id,
                startLine: index * 4, lines: 4, value: value,
                last: index == 67))
        }
    }

    func testHealthIgnoresAbsorbedRejectsWhileBuffering() {
        var snapshot = StreamDiagnosticsSnapshot()
        snapshot.video.rejectedPacketsPerSecond = 5
        XCTAssertTrue(snapshot.isDegraded)

        snapshot.buffering.enabled = true
        XCTAssertFalse(snapshot.isDegraded)

        snapshot.buffering.underrunsPerSecond = 1
        XCTAssertTrue(snapshot.isDegraded)
    }

    func testEffectiveAudioBufferFollowsVideoDelay() {
        let defaults = UserDefaults.standard
        let keys = ["networkBufferSeconds", "audioBufferMs", "networkBufferingMode"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
        }
        MainActor.assumeIsolated {
            let settings = AppSettings()
            settings.audioBufferMs = 60
            settings.networkBufferSeconds = 1.5

            // Automatic: Wi-Fi buffers, Ethernet does not.
            settings.networkBufferingMode = .automatic
            XCTAssertEqual(settings.videoPlayoutDelaySeconds(onWiFi: true), 1.5)
            XCTAssertEqual(
                settings.effectiveAudioBufferSeconds(onWiFi: true), 1.5, accuracy: 0.0001)
            XCTAssertNil(settings.videoPlayoutDelaySeconds(onWiFi: false))
            XCTAssertEqual(
                settings.effectiveAudioBufferSeconds(onWiFi: false), 0.06, accuracy: 0.0001)

            settings.networkBufferingMode = .on
            XCTAssertEqual(settings.videoPlayoutDelaySeconds(onWiFi: false), 1.5)
            settings.networkBufferingMode = .off
            XCTAssertNil(settings.videoPlayoutDelaySeconds(onWiFi: true))
        }
    }

    func testToolbarToggleOverridesAndReturnsToAutomatic() {
        // Ethernet: automatic is off, a click forces on, a second click
        // returns to automatic rather than a sticky "off".
        let ethernetOn = NetworkBufferingMode.automatic.toggled(onWiFi: false)
        XCTAssertEqual(ethernetOn, .on)
        XCTAssertEqual(ethernetOn.toggled(onWiFi: false), .automatic)

        // Wi-Fi: automatic is on, a click forces off.
        let wifiOff = NetworkBufferingMode.automatic.toggled(onWiFi: true)
        XCTAssertEqual(wifiOff, .off)
        XCTAssertEqual(wifiOff.toggled(onWiFi: true), .automatic)
    }

    func testPlayoutHoldsFramesUntilPrimedThenPacesThem() {
        let lock = NSLock()
        var times: [UInt64] = []
        let done = expectation(description: "played out")
        let buffer = VideoPlayoutBuffer(targetSeconds: 0.1) { _ in
            lock.lock()
            times.append(DispatchTime.now().uptimeNanoseconds)
            if times.count == 8 { done.fulfill() }
            lock.unlock()
        }
        let frame = Data(count: VideoReceiver.width * VideoReceiver.palHeight)
        // 0.1 s at PAL is 5 frames: four arrive in a burst and must wait.
        for _ in 0..<4 { buffer.enqueue(frame) }
        buffer.waitUntilIdle()
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock()
        XCTAssertTrue(times.isEmpty)
        lock.unlock()

        for _ in 0..<4 { buffer.enqueue(frame) }
        wait(for: [done], timeout: 2)

        lock.lock()
        let gaps = zip(times.dropFirst(), times).map { Double($0 - $1) / 1e6 }
        lock.unlock()
        // One frame per ~20 ms tick rather than a burst.
        for gap in gaps {
            XCTAssertGreaterThan(gap, 12)
            XCTAssertLessThan(gap, 40)
        }
        XCTAssertEqual(buffer.diagnosticsSnapshot().underruns, 0)
    }

    func testPlayoutCountsUnderrunAndReprimes() {
        let played = expectation(description: "drained")
        played.expectedFulfillmentCount = 5
        let buffer = VideoPlayoutBuffer(targetSeconds: 0.1) { _ in played.fulfill() }
        let frame = Data(count: VideoReceiver.width * VideoReceiver.palHeight)
        for _ in 0..<5 { buffer.enqueue(frame) }
        wait(for: [played], timeout: 2)
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertEqual(buffer.diagnosticsSnapshot().underruns, 1)
        XCTAssertEqual(buffer.diagnosticsSnapshot().bufferedFrames, 0)
    }

    func testPlayoutBoundsBacklog() {
        // Target 5 frames; the backlog cap (2 × target + 4) keeps a long
        // burst after a stall from adding latency.
        let buffer = VideoPlayoutBuffer(targetSeconds: 0.1) { _ in }
        let frame = Data(count: VideoReceiver.width * VideoReceiver.palHeight)
        for _ in 0..<40 { buffer.enqueue(frame) }
        let snapshot = buffer.diagnosticsSnapshot()
        XCTAssertLessThanOrEqual(snapshot.bufferedFrames, 14)
        XCTAssertGreaterThan(snapshot.overflowDrops, 0)
    }

    func testConcealmentPatchesSmallLossOnlyWhenBuffering() {
        let receiver = VideoReceiver()
        var frames: [Data] = []
        receiver.onFrame = { frames.append($0) }

        ingestFrame(receiver, id: 1, value: 0x1)
        XCTAssertEqual(frames.count, 1)

        // Without buffering, one lost packet drops the whole frame.
        ingestFrame(receiver, id: 2, value: 0x2, skipping: [10])
        XCTAssertEqual(frames.count, 1)

        let published = expectation(description: "patched frame")
        published.expectedFulfillmentCount = 1
        let lock = NSLock()
        var buffered: [Data] = []
        receiver.onFrame = { frame in
            lock.lock(); buffered.append(frame); lock.unlock()
            published.fulfill()
        }
        receiver.playoutDelaySeconds = 0.02
        _ = receiver.diagnosticsSnapshot() // flush the config hop

        ingestFrame(receiver, id: 3, value: 0x3, skipping: [10])
        receiver.waitForPlayoutQueue()
        wait(for: [published], timeout: 2)

        lock.lock()
        let patched = buffered[0]
        lock.unlock()
        let width = VideoReceiver.width
        XCTAssertEqual(patched[0], 0x3)
        // Rows 40-43 came from the last frame written into the buffer.
        XCTAssertNotEqual(patched[40 * width], 0x3)
        XCTAssertEqual(patched[44 * width], 0x3)
        XCTAssertEqual(receiver.diagnosticsSnapshot().concealedFrames, 1)

        // Heavy loss is still dropped rather than shown as a smear.
        ingestFrame(receiver, id: 4, value: 0x4, skipping: Set(0..<30))
        XCTAssertEqual(receiver.diagnosticsSnapshot().concealedFrames, 1)
    }

    func testConcealmentPublishesFrameWhoseLastPacketWasLost() {
        let receiver = VideoReceiver()
        receiver.playoutDelaySeconds = 5 // keep frames queued, inspect counts
        _ = receiver.diagnosticsSnapshot()

        ingestFrame(receiver, id: 1, value: 0x1)
        ingestFrame(receiver, id: 2, value: 0x2, skipping: [67])
        XCTAssertEqual(receiver.diagnosticsSnapshot().completedFrames, 1)
        // Frame 2 is published once frame 3 shows its end is not coming.
        receiver.ingest(packet(
            sequence: 500, frame: 3, startLine: 0, lines: 4,
            value: 0x3, last: false))
        let snapshot = receiver.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.completedFrames, 2)
        XCTAssertEqual(snapshot.concealedFrames, 1)
    }

    func testTransportCountersSeparateLossFromReordering() {
        let receiver = VideoReceiver()
        ingestFrame(receiver, id: 1, value: 0x1)
        // Frame 2 loses packet 5 outright and gets packet 20 late.
        for index in 0..<68 where index != 5 && index != 20 {
            receiver.ingest(packet(
                sequence: 68 &* 2 &+ UInt16(index), frame: 2,
                startLine: index * 4, lines: 4, value: 0x2,
                last: index == 67))
            if index == 30 {
                receiver.ingest(packet(
                    sequence: 68 &* 2 &+ 20, frame: 2,
                    startLine: 80, lines: 4, value: 0x2, last: false))
            }
        }
        // Frame 3 never arrives; frame 4 is complete.
        ingestFrame(receiver, id: 4, value: 0x4)

        let snapshot = receiver.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.reorderedPackets, 1)
        XCTAssertEqual(snapshot.lostPackets, 1 + 68)
        XCTAssertEqual(snapshot.droppedFrames, 2) // frame 2 incomplete, frame 3 absent
        XCTAssertEqual(snapshot.completedFrames, 2)
        XCTAssertGreaterThan(snapshot.bytes, 0)
        XCTAssertEqual(receiver.diagnosticsSnapshot().maxArrivalGapMilliseconds, 0)
    }

    func testDebugStreamCountsBytes() {
        let receiver = DebugStreamReceiver()
        receiver.ingest(Data(repeating: 0, count: 1444))
        XCTAssertEqual(receiver.bytesReceived, 1444)
    }

    func testLossRatio() {
        var video = StreamDiagnosticsSnapshot.Video()
        video.packetsPerSecond = 990
        video.lostPacketsPerSecond = 10
        XCTAssertEqual(video.lossRatio, 0.01, accuracy: 0.0001)
    }

    func testRouteStatusReportsMediumChangesOnly() {
        MainActor.assumeIsolated {
            let route = StreamRouteStatus()
            XCTAssertTrue(route.update(overWiFi: true, interfaceName: "en1"))
            XCTAssertFalse(route.update(overWiFi: true, interfaceName: "en1"))
            XCTAssertTrue(route.update(overWiFi: false, interfaceName: "en0"))
            XCTAssertEqual(route.interfaceName, "en0")
        }
    }

    func testPlayoutRetargetMovesDepthImmediately() {
        let frame = Data(count: VideoReceiver.width * VideoReceiver.palHeight)

        // Growing holds playout until the deeper buffer is full.
        let grown = VideoPlayoutBuffer(targetSeconds: 0.1) { _ in }
        grown.targetSeconds = 1.0 // 50 frames
        for _ in 0..<20 { grown.enqueue(frame) }
        grown.waitUntilIdle()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(grown.diagnosticsSnapshot().bufferedFrames, 20)

        // Shrinking skips ahead to the new depth at once, without counting
        // the skipped frames as overflow loss, and starts playing if the
        // new depth is already met.
        let played = expectation(description: "starts without a new frame")
        played.assertForOverFulfill = false
        let shrunk = VideoPlayoutBuffer(targetSeconds: 1.0) { _ in played.fulfill() }
        for _ in 0..<30 { shrunk.enqueue(frame) } // below target: not playing
        shrunk.targetSeconds = 0.2 // 10 frames
        shrunk.waitUntilIdle()
        let snapshot = shrunk.diagnosticsSnapshot()
        XCTAssertLessThanOrEqual(snapshot.bufferedFrames, 10)
        XCTAssertGreaterThanOrEqual(snapshot.bufferedFrames, 8)
        XCTAssertEqual(snapshot.overflowDrops, 0)
        wait(for: [played], timeout: 1)
    }

    func testStreamRestartIsNotCountedAsLoss() {
        let receiver = VideoReceiver()
        ingestFrame(receiver, id: 100, value: 0x1)
        // The device renumbers after a restart; the explicit reset keeps the
        // jump from reading as ~60k lost packets or dropped frames.
        receiver.resetSequenceTracking()
        ingestFrame(receiver, id: 3, value: 0x2)
        let snapshot = receiver.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.lostPackets, 0)
        XCTAssertEqual(snapshot.reorderedPackets, 0)
        XCTAssertEqual(snapshot.droppedFrames, 0)
        XCTAssertEqual(snapshot.completedFrames, 2)
    }
}
