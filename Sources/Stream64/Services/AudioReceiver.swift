import Foundation
import Network
import AVFoundation
import os

/// Receives the Ultimate audio stream (16-bit signed stereo, little endian,
/// 47983 Hz on a PAL Ultimate 64) over UDP and plays it through AVAudioEngine.
///
/// Playback uses a pull model: an AVAudioSourceNode pulls samples from a ring
/// buffer in real time. This keeps latency bounded — network hiccups produce a
/// brief silence instead of permanently growing delay, and any backlog beyond
/// the jitter-buffer target is trimmed.
///
/// Packet layout: u16 sequence, then 192 stereo sample pairs (768 bytes).
final class AudioReceiver {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "audio-receiver")

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let renderFormat: AVAudioFormat

    /// Sample rate of the Ultimate audio stream.
    private static let sampleRate: Double = 47983.0

    var volume: Float {
        get { muted ? storedVolume : engine.mainMixerNode.outputVolume }
        set {
            storedVolume = newValue
            if !muted { engine.mainMixerNode.outputVolume = newValue }
        }
    }

    /// Silences playback without stopping the stream — used in the
    /// multi-viewer grid so only one device is audible at a time.
    var muted: Bool = false {
        didSet { engine.mainMixerNode.outputVolume = muted ? 0 : storedVolume }
    }
    private var storedVolume: Float = 1.0

    /// Target jitter buffer depth in seconds. Playback starts once this much
    /// audio is buffered; backlog beyond target + slack is dropped.
    var bufferSeconds: Double = 0.06

    /// RF mode: filter playback like a TV speaker fed from the antenna —
    /// mono, band-limited, with a bed of static. Written from the main
    /// thread, read on the audio thread (a torn read is harmless here).
    var rfAudioEnabled: Bool = false

    // RF filter state (audio thread only). The .r half of rfLowState is
    // reused as the noise low-pass state.
    private var rfLowState: (l: Float, r: Float) = (0, 0)
    private var rfLowState2: Float = 0
    private var rfHighState: (l: Float, r: Float) = (0, 0)
    private var rfHighPrev: (l: Float, r: Float) = (0, 0)
    private var rfNoiseSeed: UInt32 = 0x12345678
    private var rfHumPhase: Float = 0

    // MARK: - Ring buffer (interleaved stereo floats), guarded by `lock`.

    private static let capacityFrames = Int(sampleRate * 2) // ~2 s
    private var ring = [Float](repeating: 0, count: capacityFrames * 2)
    private var readIndex = 0        // frames
    private var writeIndex = 0       // frames
    private var framesAvailable = 0
    private var primed = false
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()

    private var started = false

    init() {
        // Standard (deinterleaved) stereo float — AVAudioEngine node
        // connections require non-interleaved formats.
        renderFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!

        let node = AVAudioSourceNode(format: renderFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
    }

    deinit {
        lock.deallocate()
    }

    func start(port: UInt16) throws {
        stop()

        os_unfair_lock_lock(lock)
        readIndex = 0
        writeIndex = 0
        framesAvailable = 0
        primed = false
        os_unfair_lock_unlock(lock)

        try engine.start()
        started = true

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if started {
            engine.stop()
            started = false
        }
    }

    // MARK: - Network side (writer)

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self else { return }
            if let data {
                self.handlePacket(data)
            }
            if error == nil, let connection {
                self.receive(on: connection)
            }
        }
    }

    private func handlePacket(_ data: Data) {
        guard started, data.count > 2 else { return }
        let payload = data.dropFirst(2)
        let frameCount = payload.count / 4 // 2 channels × 2 bytes
        guard frameCount > 0 else { return }

        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            os_unfair_lock_lock(lock)
            for i in 0..<frameCount {
                // Ring full: drop the oldest frame to stay bounded.
                if framesAvailable == Self.capacityFrames {
                    readIndex = (readIndex + 1) % Self.capacityFrames
                    framesAvailable -= 1
                }
                let l = base.loadUnaligned(fromByteOffset: i * 4, as: Int16.self)
                let r = base.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self)
                ring[writeIndex * 2] = Float(l) / 32768.0
                ring[writeIndex * 2 + 1] = Float(r) / 32768.0
                writeIndex = (writeIndex + 1) % Self.capacityFrames
                framesAvailable += 1
            }
            os_unfair_lock_unlock(lock)
        }
    }

    // MARK: - Render side (reader, audio thread)

    private func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let targetFrames = max(1, Int(bufferSeconds * Self.sampleRate))
        // Allow bursts up to target + slack before trimming.
        let slackFrames = max(targetFrames, Int(0.1 * Self.sampleRate))

        // Wait (in silence) until the jitter buffer is primed.
        if !primed {
            if framesAvailable >= targetFrames {
                primed = true
            } else {
                left.update(repeating: 0, count: frames)
                right.update(repeating: 0, count: frames)
                return
            }
        }

        // Trim excess backlog so latency stays bounded at the target.
        if framesAvailable > targetFrames + slackFrames {
            let drop = framesAvailable - targetFrames
            readIndex = (readIndex + drop) % Self.capacityFrames
            framesAvailable -= drop
        }

        let toCopy = min(frames, framesAvailable)
        for i in 0..<toCopy {
            left[i] = ring[readIndex * 2]
            right[i] = ring[readIndex * 2 + 1]
            readIndex = (readIndex + 1) % Self.capacityFrames
        }
        framesAvailable -= toCopy

        if toCopy < frames {
            // Underrun: fill with silence and re-prime so we rebuild the
            // jitter buffer instead of crackling packet by packet.
            left.advanced(by: toCopy).update(repeating: 0, count: frames - toCopy)
            right.advanced(by: toCopy).update(repeating: 0, count: frames - toCopy)
            primed = false
        }

        if rfAudioEnabled {
            applyRFFilter(left: left, right: right, frames: frames)
        }
    }

    /// TV-speaker-over-antenna simulation:
    /// - mono (the RF modulator carries one channel)
    /// - ~200 Hz high-pass (small speaker has no bass)
    /// - ~3 kHz low-pass, double pole (narrow broadcast audio + paper cone)
    /// - constant hiss bed + faint 50 Hz hum
    private func applyRFFilter(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        // One-pole coefficients for the fixed stream rate.
        let lpAlpha: Float = 0.30   // ~3.3 kHz per pole at 47983 Hz
        let hpAlpha: Float = 0.974  // ~200 Hz high-pass
        let humStep = Float(2 * Double.pi * 50.0 / Self.sampleRate)

        for i in 0..<frames {
            // Mono fold.
            var s = (left[i] + right[i]) * 0.5

            // Low-pass, two cascaded poles (12 dB/oct) — a single pole is
            // too gentle to hear against SID content.
            rfLowState.l += lpAlpha * (s - rfLowState.l)
            rfLowState2 += lpAlpha * (rfLowState.l - rfLowState2)
            s = rfLowState2

            // High-pass (one pole).
            let hp = hpAlpha * (rfHighState.l + s - rfHighPrev.l)
            rfHighPrev.l = s
            rfHighState.l = hp
            s = hp

            // Drive into soft clip — small TV amps distort early.
            s = tanh(s * 2.2) * 0.85

            // Static: white-noise hiss through the same low-pass feel.
            rfNoiseSeed = rfNoiseSeed &* 1664525 &+ 1013904223
            let white = Float(rfNoiseSeed >> 8) / Float(1 << 24) - 0.5
            rfLowState.r += 0.30 * (white - rfLowState.r)   // reuse as noise LP state
            s += rfLowState.r * 0.035

            // Faint mains hum.
            rfHumPhase += humStep
            if rfHumPhase > 2 * Float.pi { rfHumPhase -= 2 * Float.pi }
            s += sin(rfHumPhase) * 0.010

            left[i] = s
            right[i] = s
        }
    }
}
