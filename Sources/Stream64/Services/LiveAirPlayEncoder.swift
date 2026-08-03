import Foundation
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

private struct AirPlayRFProcessor {
    private var lowState: Float = 0
    private var lowState2: Float = 0
    private var highState: Float = 0
    private var highState2: Float = 0
    private var highPrevious: Float = 0
    private var highPrevious2: Float = 0
    private var noiseState: Float = 0
    private var noiseSeed: UInt32 = 0x12345678
    private var humPhase: Float = 0

    mutating func reset() {
        self = AirPlayRFProcessor()
    }

    mutating func process(_ samples: inout [Float]) {
        let lowAlpha: Float = 0.30
        let highAlpha: Float = 0.958
        let humStep = Float(
            2 * Double.pi * 50 / LiveAirPlayEncoder.sourceSampleRate)
        for frame in 0..<(samples.count / 2) {
            var value = (samples[frame * 2] + samples[frame * 2 + 1]) * 0.5

            lowState += lowAlpha * (value - lowState)
            lowState2 += lowAlpha * (lowState - lowState2)
            value = lowState2

            let hp1 = highAlpha * (highState + value - highPrevious)
            highPrevious = value
            highState = hp1
            let hp2 = highAlpha * (highState2 + hp1 - highPrevious2)
            highPrevious2 = hp1
            highState2 = hp2
            value = tanh(hp2 * 2.2) * 0.85

            noiseSeed = noiseSeed &* 1664525 &+ 1013904223
            let white = Float(noiseSeed >> 8) / Float(1 << 24) - 0.5
            noiseState += 0.30 * (white - noiseState)
            value += noiseState * 0.035

            humPhase += humStep
            if humPhase > 2 * Float.pi { humPhase -= 2 * Float.pi }
            value += sin(humPhase) * 0.010

            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
    }
}

/// Converts the selected Ultimate's 47,983 Hz stereo float stream into a
/// bounded, monotonic 48 kHz AAC/fMP4 HLS stream. All encoding work happens
/// on `queue`; the UDP receiver callback only schedules a copied sample array.
final class LiveAirPlayEncoder: NSObject, AVAssetWriterDelegate {
    enum EncoderError: LocalizedError {
        case setup(String)
        case conversion(String)
        case sampleBuffer(OSStatus)

        var errorDescription: String? {
            switch self {
            case .setup(let message): return "AirPlay encoder setup failed: \(message)"
            case .conversion(let message): return "AirPlay conversion failed: \(message)"
            case .sampleBuffer(let status):
                return "AirPlay sample-buffer creation failed (\(status))."
            }
        }
    }

    static let sourceSampleRate = 47_983.0
    static let outputSampleRate = 48_000.0
    static let channels: AVAudioChannelCount = 2
    static let segmentDuration = 0.5

    var onFailure: ((Error) -> Void)?

    private let server: LiveHLSServer
    private let queue = DispatchQueue(label: "stream64.airplay.encoder")
    private let segmentLock = NSLock()
    private let maximumPendingFrames = Int(sourceSampleRate * 2.5)

    private var converter: AVAudioConverter?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var outputFormatDescription: CMAudioFormatDescription?
    private var pendingBlocks: [[Float]] = []
    private var pendingFrames = 0
    private var pendingSilenceFrames = 0
    private var drainRetryScheduled = false
    private var running = false
    private var outputFramePosition: Int64 = 0
    private var markNextSegmentDiscontinuous = false
    private var rfProcessor = AirPlayRFProcessor()
    private var silenceTimer: DispatchSourceTimer?
    private var lastRealInputUptime: UInt64 = 0

    init(server: LiveHLSServer) {
        self.server = server
        super.init()
    }

    func start() throws {
        let inputFormat = AVAudioFormat(
            standardFormatWithSampleRate: Self.sourceSampleRate,
            channels: Self.channels)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.outputSampleRate,
            channels: Self.channels,
            interleaved: true)
        guard let inputFormat, let outputFormat,
              let converter = AVAudioConverter(
                from: inputFormat, to: outputFormat)
        else {
            throw EncoderError.setup("Could not create the PCM converter.")
        }

        var asbd = outputFormat.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription)
        guard formatStatus == noErr, let formatDescription else {
            throw EncoderError.sampleBuffer(formatStatus)
        }

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(
            seconds: Self.segmentDuration,
            preferredTimescale: 48_000)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Int(Self.outputSampleRate),
                AVNumberOfChannelsKey: Int(Self.channels),
                AVEncoderBitRateKey: 192_000,
            ],
            sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw EncoderError.setup("AVAssetWriter rejected its audio input.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw EncoderError.setup(
                writer.error?.localizedDescription ?? "Writer did not start.")
        }
        writer.startSession(atSourceTime: .zero)

        queue.sync {
            self.converter = converter
            self.writer = writer
            self.writerInput = input
            self.outputFormatDescription = formatDescription
            self.pendingBlocks.removeAll()
            self.pendingFrames = 0
            self.pendingSilenceFrames = 0
            self.outputFramePosition = 0
            self.running = true
            self.lastRealInputUptime = DispatchTime.now().uptimeNanoseconds
            self.startSilenceTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.silenceTimer?.cancel()
            self.silenceTimer = nil
            self.writerInput?.markAsFinished()
            // Segments already delivered to the delegate are complete; the
            // in-progress tail is intentionally discarded on route teardown.
            self.writer?.cancelWriting()
            self.pendingBlocks.removeAll()
            self.pendingFrames = 0
            self.pendingSilenceFrames = 0
            self.converter = nil
            self.writerInput = nil
            self.writer = nil
        }
    }

    func enqueue(
        samples: [Float],
        gain: Float = 1,
        rfEnabled: Bool = false
    ) {
        guard samples.count >= 2 else { return }
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.lastRealInputUptime = DispatchTime.now().uptimeNanoseconds
            var block = samples
            if rfEnabled {
                self.rfProcessor.process(&block)
            }
            if abs(gain - 1) >= 0.0001 {
                for index in block.indices {
                    block[index] = min(
                        1, max(-1, block[index] * gain))
                }
            }
            self.pendingBlocks.append(block)
            self.pendingFrames += block.count / 2
            while self.pendingFrames > self.maximumPendingFrames,
                  !self.pendingBlocks.isEmpty {
                let removed = self.pendingBlocks.removeFirst()
                let frames = removed.count / 2
                self.pendingFrames -= frames
                self.pendingSilenceFrames += frames
            }
            self.drain()
        }
    }

    func insertDiscontinuity() {
        segmentLock.lock()
        markNextSegmentDiscontinuous = true
        segmentLock.unlock()
        queue.async { [weak self] in
            self?.rfProcessor.reset()
        }
    }

    private func drain() {
        guard running, let input = writerInput else { return }
        while input.isReadyForMoreMediaData {
            let samples: [Float]
            if pendingSilenceFrames > 0 {
                let frames = min(1_024, pendingSilenceFrames)
                pendingSilenceFrames -= frames
                samples = [Float](repeating: 0, count: frames * 2)
            } else if !pendingBlocks.isEmpty {
                samples = pendingBlocks.removeFirst()
                pendingFrames -= samples.count / 2
            } else {
                return
            }

            do {
                guard let sampleBuffer = try makeSampleBuffer(
                    from: samples) else { continue }
                if !input.append(sampleBuffer) {
                    throw EncoderError.setup(
                        writer?.error?.localizedDescription
                        ?? "AVAssetWriter rejected live audio.")
                }
            } catch {
                fail(error)
                return
            }
        }

        guard (!pendingBlocks.isEmpty || pendingSilenceFrames > 0),
              !drainRetryScheduled else { return }
        drainRetryScheduled = true
        queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { return }
            self.drainRetryScheduled = false
            self.drain()
        }
    }

    /// Keep the global HLS timeline alive when switching to a receiver that
    /// has not begun delivering UDP audio yet. Without this heartbeat the
    /// live playlist stalls, causing AVPlayer to abandon its AirPlay route
    /// and render locally. Twenty-millisecond silence blocks advance at
    /// real-time cadence and are replaced immediately when real PCM resumes.
    private func startSilenceTimer() {
        silenceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(20),
            repeating: .milliseconds(20),
            leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let silenceThreshold: UInt64 = 40_000_000
            guard now - self.lastRealInputUptime >= silenceThreshold,
                  self.pendingFrames < Int(Self.sourceSampleRate * 0.25)
            else { return }
            let frames = 960 // approximately 20 ms at 47,983 Hz
            self.pendingBlocks.append(
                [Float](repeating: 0, count: frames * 2))
            self.pendingFrames += frames
            self.drain()
        }
        silenceTimer = timer
        timer.resume()
    }

    private func makeSampleBuffer(
        from interleavedSamples: [Float]
    ) throws -> CMSampleBuffer? {
        guard let converter,
              let formatDescription = outputFormatDescription,
              let inputFormat = converter.inputFormat as AVAudioFormat?,
              let outputFormat = converter.outputFormat as AVAudioFormat?
        else { return nil }

        let inputFrames = interleavedSamples.count / 2
        guard inputFrames > 0,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(inputFrames))
        else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(inputFrames)
        guard let channels = inputBuffer.floatChannelData else { return nil }
        for frame in 0..<inputFrames {
            channels[0][frame] = interleavedSamples[frame * 2]
            channels[1][frame] = interleavedSamples[frame * 2 + 1]
        }

        let capacity = AVAudioFrameCount(
            ceil(Double(inputFrames) *
                 Self.outputSampleRate / Self.sourceSampleRate) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity)
        else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status == .haveData || status == .inputRanDry else {
            throw EncoderError.conversion(
                conversionError?.localizedDescription
                ?? "Unexpected converter status \(status.rawValue).")
        }
        let frames = Int(outputBuffer.frameLength)
        guard frames > 0,
              let samples = outputBuffer.int16ChannelData?[0]
        else { return nil }

        let byteCount = frames * Int(
            outputFormat.streamDescription.pointee.mBytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        var result = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard result == kCMBlockBufferNoErr, let blockBuffer else {
            throw EncoderError.sampleBuffer(result)
        }
        result = CMBlockBufferReplaceDataBytes(
            with: samples,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount)
        guard result == kCMBlockBufferNoErr else {
            throw EncoderError.sampleBuffer(result)
        }

        let pts = CMTime(
            value: outputFramePosition,
            timescale: 48_000)
        var sampleBuffer: CMSampleBuffer?
        result = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frames,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard result == noErr else {
            throw EncoderError.sampleBuffer(result)
        }
        outputFramePosition += Int64(frames)
        return sampleBuffer
    }

    private func fail(_ error: Error) {
        running = false
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType
    ) {
        switch segmentType {
        case .initialization:
            server.setInitializationSegment(segmentData)
        case .separable:
            segmentLock.lock()
            let discontinuity = markNextSegmentDiscontinuous
            markNextSegmentDiscontinuous = false
            segmentLock.unlock()
            server.appendMediaSegment(
                segmentData,
                duration: Self.segmentDuration,
                discontinuity: discontinuity)
        @unknown default:
            break
        }
    }
}
