import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Writes either the unfiltered Ultimate stream or Metal-filtered BGRA frames
/// to a QuickTime movie.
///
/// Input callbacks only copy into short, bounded queues. Pixel conversion and
/// AVAssetWriter work happen on `writerQueue`, so a slow disk or encoder never
/// blocks UDP reception or the Metal display path.
final class RecordingController: @unchecked Sendable {
    static let movieHeight = VideoReceiver.palHeight
    static let audioSampleRate = 47_983.0
    /// AAC accepts standard rates; the Ultimate's 47,983 Hz source PCM is
    /// converted by AVFoundation to this nearest supported output rate.
    static let encodedAudioSampleRate = 48_000.0
    static let maximumQueuedVideoFrames = 12
    static let maximumQueuedAudioPackets = 96
    static let sourceVideoBitRate = 3_000_000
    /// CRT masks, scanlines, dithering, and RF noise are deliberately
    /// high-frequency detail that low-bitrate H.264 turns into moiré.
    static let filteredVideoBitRate = 35_000_000

    private struct VideoPacket {
        enum Contents {
            case indexed(Data)
            case pixelBuffer(CVPixelBuffer)
        }

        let contents: Contents
        let presentationTime: CMTime
    }

    private struct AudioPacket {
        let samples: [Float]
        let presentationTime: CMTime
    }

    private let writerQueue = DispatchQueue(label: "recording-controller.writer")
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoQueue: [VideoPacket] = []
    private var audioQueue: [AudioPacket] = []
    private var isFinishing = false
    private var startUptime: UInt64 = 0
    private var palette = C64Palette.pepto
    private var movieWidth = VideoReceiver.width
    private var movieHeight = VideoReceiver.palHeight
    private var acceptsIndexedFrames = true

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writer != nil && !isFinishing
    }

    private var droppedVideoFrames: Int = 0
    private var droppedAudioPackets: Int = 0

    func diagnosticsSnapshot() -> RecordingDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return RecordingDiagnostics(
            queuedVideoFrames: videoQueue.count,
            droppedVideoFrames: droppedVideoFrames,
            droppedAudioPackets: droppedAudioPackets)
    }

    func start(
        url: URL,
        palette: [SIMD4<UInt8>],
        outputSize: CGSize = CGSize(
            width: VideoReceiver.width, height: VideoReceiver.palHeight),
        videoBitRate: Int = sourceVideoBitRate,
        videoCodec: AVVideoCodecType = .h264,
        acceptsIndexedFrames: Bool = true,
        requiresMetalCompatiblePixelBuffers: Bool = false
    ) throws {
        guard palette.count == 16 else { throw RecordingError.invalidPalette }
        let width = Int(outputSize.width.rounded(.down))
        let height = Int(outputSize.height.rounded(.down))
        guard width > 0, height > 0 else { throw RecordingError.invalidOutputSize }
        lock.lock()
        defer { lock.unlock() }
        guard writer == nil else { throw RecordingError.alreadyRecording }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if videoCodec == .h264 {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.encodedAudioSampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
        audioInput.expectsMediaDataInRealTime = true

        var pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        if requiresMetalCompatiblePixelBuffers {
            // The filtered renderer wraps these buffers in CVMetalTextures,
            // so the writer's pool must allocate IOSurface-backed storage.
            pixelBufferAttributes[kCVPixelBufferMetalCompatibilityKey as String] = true
            pixelBufferAttributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes)
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecordingError.cannotAddInputs
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.cannotStart
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.pixelBufferAdaptor = adaptor
        self.palette = palette
        self.movieWidth = width
        self.movieHeight = height
        self.acceptsIndexedFrames = acceptsIndexedFrames
        startUptime = DispatchTime.now().uptimeNanoseconds
        videoQueue.removeAll(keepingCapacity: true)
        audioQueue.removeAll(keepingCapacity: true)
        droppedVideoFrames = 0
        droppedAudioPackets = 0
        isFinishing = false
    }

    func enqueue(frame: Data) {
        guard VideoReceiver.isSupportedFrameHeight(frame.count / VideoReceiver.width) else { return }
        lock.lock()
        guard writer != nil, !isFinishing, acceptsIndexedFrames else {
            lock.unlock()
            return
        }
        if videoQueue.count == Self.maximumQueuedVideoFrames {
            videoQueue.removeFirst()
            droppedVideoFrames += 1
        }
        videoQueue.append(VideoPacket(contents: .indexed(frame), presentationTime: elapsedTimeLocked()))
        lock.unlock()
        scheduleDrain()
    }

    /// Called after the Metal command buffer has completed rendering the
    /// filtered output into a CVPixelBuffer-backed texture.
    func enqueue(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        guard writer != nil, !isFinishing,
              CVPixelBufferGetWidth(pixelBuffer) == movieWidth,
              CVPixelBufferGetHeight(pixelBuffer) == movieHeight else {
            lock.unlock()
            return
        }
        if videoQueue.count == Self.maximumQueuedVideoFrames {
            videoQueue.removeFirst()
            droppedVideoFrames += 1
        }
        videoQueue.append(VideoPacket(
            contents: .pixelBuffer(pixelBuffer),
            presentationTime: elapsedTimeLocked()))
        lock.unlock()
        scheduleDrain()
    }

    /// Allocates a buffer from the active adaptor's encoder-owned pool.
    /// The caller may render into this buffer (including through Metal) and
    /// then enqueue it. Never substitute independently-created buffers here:
    /// AVAssetWriter can retain its pool buffers until encoding completes.
    func makeFilteredPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        guard writer != nil, !isFinishing,
              let pool = pixelBufferAdaptor?.pixelBufferPool else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess else {
            return nil
        }
        return pixelBuffer
    }

    func enqueue(audioSamples: [Float]) {
        guard !audioSamples.isEmpty, audioSamples.count.isMultiple(of: 2) else { return }
        lock.lock()
        guard writer != nil, !isFinishing else {
            lock.unlock()
            return
        }
        if audioQueue.count == Self.maximumQueuedAudioPackets {
            audioQueue.removeFirst()
            droppedAudioPackets += 1
        }
        audioQueue.append(AudioPacket(samples: audioSamples, presentationTime: elapsedTimeLocked()))
        lock.unlock()
        scheduleDrain()
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock()
        guard let writer, !isFinishing else {
            lock.unlock()
            completion(.failure(RecordingError.notRecording))
            return
        }
        isFinishing = true
        let url = writer.outputURL
        lock.unlock()

        // Retain the controller through `finishWriting`: SessionManager can
        // release a session immediately after disconnect, but its last movie
        // must still be finalized on disk.
        writerQueue.async {
            self.drain()
            self.lock.lock()
            let videoInput = self.videoInput
            let audioInput = self.audioInput
            self.lock.unlock()
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting {
                let result: Result<URL, Error>
                if writer.status == .completed {
                    result = .success(url)
                } else {
                    result = .failure(writer.error ?? RecordingError.finishFailed)
                }
                self.lock.lock()
                self.writer = nil
                self.videoInput = nil
                self.audioInput = nil
                self.pixelBufferAdaptor = nil
                self.videoQueue.removeAll(keepingCapacity: true)
                self.audioQueue.removeAll(keepingCapacity: true)
                self.isFinishing = false
                self.lock.unlock()
                completion(result)
            }
        }
    }

    private func scheduleDrain() {
        writerQueue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let video = videoQueue.first,
                  let adaptor = pixelBufferAdaptor,
                  let input = videoInput,
                  input.isReadyForMoreMediaData else {
                lock.unlock()
                break
            }
            videoQueue.removeFirst()
            let palette = self.palette
            let pixelBufferPool = adaptor.pixelBufferPool
            lock.unlock()

            let pixelBuffer: CVPixelBuffer?
            switch video.contents {
            case .indexed(let frame):
                pixelBuffer = makePixelBuffer(
                    frame: frame, palette: palette,
                    width: movieWidth, height: movieHeight,
                    pixelBufferPool: pixelBufferPool)
            case .pixelBuffer(let buffer):
                pixelBuffer = buffer
            }
            if let pixelBuffer {
                _ = adaptor.append(pixelBuffer, withPresentationTime: video.presentationTime)
            }
        }

        while true {
            lock.lock()
            guard let audio = audioQueue.first,
                  let input = audioInput,
                  input.isReadyForMoreMediaData else {
                lock.unlock()
                break
            }
            audioQueue.removeFirst()
            lock.unlock()

            if let sampleBuffer = makeAudioSampleBuffer(
                samples: audio.samples, presentationTime: audio.presentationTime) {
                _ = input.append(sampleBuffer)
            }
        }
    }

    private func elapsedTimeLocked() -> CMTime {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startUptime
        return CMTime(value: Int64(elapsed), timescale: 1_000_000_000)
    }

    private func makePixelBuffer(
        frame: Data,
        palette: [SIMD4<UInt8>],
        width: Int,
        height: Int,
        pixelBufferPool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        let sourceHeight = frame.count / VideoReceiver.width
        guard VideoReceiver.isSupportedFrameHeight(sourceHeight),
              width == VideoReceiver.width,
              height >= sourceHeight else { return nil }
        guard let pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pixelBufferPool,
            &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        memset(base, 0, bytesPerRow * height)
        frame.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<sourceHeight {
                let destination = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<VideoReceiver.width {
                    let color = palette[Int(sourceBase[y * VideoReceiver.width + x] & 0x0F)]
                    let offset = x * 4
                    destination[offset] = color.z
                    destination[offset + 1] = color.y
                    destination[offset + 2] = color.x
                    destination[offset + 3] = color.w
                }
            }
        }
        return pixelBuffer
    }

    private func makeAudioSampleBuffer(
        samples: [Float],
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.audioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format) == noErr,
            let format else { return nil }
        var blockBuffer: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let blockBuffer else { return nil }
        let copyResult = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copyResult == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(Self.audioSampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: samples.count / 2,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    enum RecordingError: LocalizedError {
        case alreadyRecording, notRecording, invalidPalette, invalidOutputSize, cannotAddInputs, cannotStart, finishFailed, cannotStartFilteredRendering

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already in progress."
            case .notRecording: return "No recording is in progress."
            case .invalidPalette: return "The selected C64 palette is invalid."
            case .invalidOutputSize: return "The selected movie size is invalid."
            case .cannotAddInputs: return "Could not configure the movie inputs."
            case .cannotStart: return "Could not start the movie writer."
            case .finishFailed: return "Could not finish the movie."
            case .cannotStartFilteredRendering: return "Could not start filtered movie rendering."
            }
        }
    }
}
