import Foundation
import Network
import AVFoundation
import CoreAudio
import AudioToolbox
import os

private let logger = Logger(subsystem: "net.bosschaart.Stream64", category: "AudioReceiver")

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

    /// Lifetime packet count for this receiver instance. Stream pickup uses
    /// a per-connect baseline rather than comparing this value with zero.
    /// Written on the receive queue; racy polling reads are fine.
    private(set) var packetsReceived: Int = 0

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
    private var powerOffCrackleRemaining = 0
    private var powerOffCrackleTotal = 1
    private var powerOffCrackleImpulse: Float = 0
    private var powerOffCracklePhase: Float = 0

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
    private var configChangeObserver: NSObjectProtocol?

    /// Multiple visualization windows (Spectrum Analyzer, Lissajous Scope,
    /// Spectrogram) can tap the real decoded audio at once, so — same
    /// multicast pattern `DebugStreamReceiver` uses for trace entries —
    /// observers are keyed by token rather than a single closure.
    /// Broadcasts interleaved stereo `[Float]` (L, R, L, R, ...) once per
    /// packet, from inside `handlePacket` on the receiver's own queue —
    /// never from the real-time `render(...)` audio-thread callback, so
    /// taps add no risk to playback.
    private var sampleObservers: [UUID: ([Float]) -> Void] = [:]

    @discardableResult
    func addSampleObserver(_ observer: @escaping ([Float]) -> Void) -> UUID {
        let id = UUID()
        queue.async { [weak self] in self?.sampleObservers[id] = observer }
        return id
    }

    func removeSampleObserver(_ id: UUID) {
        queue.async { [weak self] in self?.sampleObservers.removeValue(forKey: id) }
    }

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

        // A stopped engine has no active render callback, so it is safe to
        // reset the TV-speaker filter before starting a fresh stream.
        rfLowState = (0, 0)
        rfLowState2 = 0
        rfHighState = (0, 0)
        rfHighPrev = (0, 0)
        rfHumPhase = 0
        powerOffCrackleRemaining = 0
        powerOffCrackleImpulse = 0
        powerOffCracklePhase = 0

        pinOutputToCurrentDefaultDevice()

        do {
            try engine.start()
        } catch {
            // CoreAudio can refuse (error 35) when the engine is restarted
            // in quick succession — e.g. stop/start during a reconnect.
            // A brief pause and one retry clears it.
            Thread.sleep(forTimeInterval: 0.25)
            try engine.start()
        }
        started = true

        // AVAudioEngine's automatic output-device selection is unreliable
        // when the system default output is an aggregate/multi-output
        // device (e.g. one built with BlackHole for recording): it can
        // silently bind to a real hardware device instead. Re-pinning here
        // whenever CoreAudio reconfigures the device graph (an audio
        // device added/removed, an aggregate device edited, etc.) recovers
        // from that without requiring the user to restart the app.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                guard let self, self.started else { return }
                self.pinOutputToCurrentDefaultDevice()
                if !self.engine.isRunning {
                    try? self.engine.start()
                }
            }
        }

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
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        if started {
            engine.stop()
            started = false
        }
    }

    /// Forces the engine's output unit onto whatever CoreAudio currently
    /// reports as the default output device, rather than trusting
    /// AVAudioEngine to pick it automatically (see the comment at the
    /// `configChangeObserver` registration above for why).
    private func pinOutputToCurrentDefaultDevice() {
        guard let audioUnit = engine.outputNode.audioUnit else { return }

        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let readStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil,
            &deviceIDSize, &deviceID)
        guard readStatus == noErr else {
            logger.error("Could not read default output device (status \(readStatus))")
            return
        }

        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if setStatus != noErr {
            logger.error("Could not pin output unit to device \(deviceID) (status \(setStatus))")
        }
    }

    /// Arm a short, synthesized high-voltage discharge sound. State is
    /// guarded by the existing audio lock and consumed allocation-free by the
    /// source-node render callback.
    func playPowerOffCrackle() {
        os_unfair_lock_lock(lock)
        powerOffCrackleTotal = Int(Self.sampleRate * 0.85)
        powerOffCrackleRemaining = powerOffCrackleTotal
        powerOffCrackleImpulse = 0
        powerOffCracklePhase = 0
        rfNoiseSeed ^= 0xA5A5_5A5A
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Network side (writer)

    static func isStructurallyValidPacket(_ data: Data) -> Bool {
        data.count == 770
    }

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
        // Ultimate audio packets contain a 2-byte sequence plus exactly
        // 192 stereo Int16 frames (768 bytes). Do not let unrelated or
        // truncated UDP traffic satisfy DeviceSession's live-stream probe.
        guard started, Self.isStructurallyValidPacket(data) else { return }
        packetsReceived += 1
        let payload = data.dropFirst(2)
        let frameCount = payload.count / 4 // 2 channels × 2 bytes
        guard frameCount > 0 else { return }

        // Skip building the tap buffer entirely when nobody's listening —
        // the common case (no visualization window open).
        let tapping = !sampleObservers.isEmpty
        var tapSamples: [Float] = []
        if tapping { tapSamples.reserveCapacity(frameCount * 2) }

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
                let lf = Float(l) / 32768.0
                let rf = Float(r) / 32768.0
                ring[writeIndex * 2] = lf
                ring[writeIndex * 2 + 1] = rf
                writeIndex = (writeIndex + 1) % Self.capacityFrames
                framesAvailable += 1
                if tapping {
                    tapSamples.append(lf)
                    tapSamples.append(rf)
                }
            }
            os_unfair_lock_unlock(lock)
        }

        if tapping {
            for observer in sampleObservers.values { observer(tapSamples) }
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
                applyPowerOffCrackle(
                    left: left, right: right, frames: frames)
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
        applyPowerOffCrackle(left: left, right: right, frames: frames)
    }

    private func applyPowerOffCrackle(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        guard powerOffCrackleRemaining > 0 else { return }

        let phaseStep = Float(2 * Double.pi * 78.0 / Self.sampleRate)
        for index in 0..<frames {
            guard powerOffCrackleRemaining > 0 else { break }
            let elapsed = 1.0 - Float(powerOffCrackleRemaining)
                / Float(powerOffCrackleTotal)
            let envelope = pow(max(0, 1.0 - elapsed), 2.35)

            rfNoiseSeed = rfNoiseSeed &* 1664525 &+ 1013904223
            let random = Float(rfNoiseSeed >> 8) / Float(1 << 24)
            let white = random - 0.5

            // Sparse, irregular dielectric snaps riding on decaying hiss.
            powerOffCrackleImpulse *= 0.86
            if random > 0.986 {
                powerOffCrackleImpulse += (random - 0.986) * 8.0
            }

            // Initial low electrical pop as the flyback/high voltage drains.
            powerOffCracklePhase += phaseStep
            let pop = sin(powerOffCracklePhase)
                * exp(-elapsed * 22.0) * 0.075
            let hiss = white * envelope * 0.040
            let snaps = powerOffCrackleImpulse * envelope * 0.12
            let sample = pop + hiss + snaps

            left[index] = clampAudio(left[index] + sample)
            right[index] = clampAudio(right[index] + sample)
            powerOffCrackleRemaining -= 1
        }
    }

    private func clampAudio(_ value: Float) -> Float {
        min(1, max(-1, value))
    }

    /// TV-speaker-over-antenna simulation:
    /// - mono (the RF modulator carries one channel)
    /// - ~330 Hz high-pass, double pole (small TV speaker has very little bass)
    /// - ~3 kHz low-pass, double pole (narrow broadcast audio + paper cone)
    /// - constant hiss bed + faint 50 Hz hum
    private func applyRFFilter(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        // One-pole coefficients for the fixed stream rate.
        let lpAlpha: Float = 0.30   // ~3.3 kHz per pole at 47983 Hz
        let hpAlpha: Float = 0.958  // ~330 Hz high-pass per pole
        let humStep = Float(2 * Double.pi * 50.0 / Self.sampleRate)

        for i in 0..<frames {
            // Mono fold.
            var s = (left[i] + right[i]) * 0.5

            // Low-pass, two cascaded poles (12 dB/oct) — a single pole is
            // too gentle to hear against SID content.
            rfLowState.l += lpAlpha * (s - rfLowState.l)
            rfLowState2 += lpAlpha * (rfLowState.l - rfLowState2)
            s = rfLowState2

            // High-pass, two cascaded poles (12 dB/oct). This removes far
            // more SID bass than the old single ~200 Hz pole and better
            // resembles the small internal speaker in an inexpensive TV.
            let hp1 = hpAlpha * (rfHighState.l + s - rfHighPrev.l)
            rfHighPrev.l = s
            rfHighState.l = hp1
            let hp2 = hpAlpha * (rfHighState.r + hp1 - rfHighPrev.r)
            rfHighPrev.r = hp1
            rfHighState.r = hp2
            s = hp2

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
