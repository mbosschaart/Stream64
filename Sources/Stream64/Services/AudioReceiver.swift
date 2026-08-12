import Foundation
import Network
import AVFoundation
import CoreAudio
import AudioToolbox
import os

private let logger = Logger(subsystem: "net.bosschaart.Stream64", category: "AudioReceiver")

/// Receives the Ultimate audio stream (16-bit signed stereo, little endian,
/// ~47983 Hz PAL / ~47940 Hz NTSC) over UDP and plays it through AVAudioEngine.
/// Playback uses the PAL rate; the NTSC offset is ~0.09% and inaudible as
/// pitch error, while RF mains hum follows `mainsHumFrequencyHz`.
///
/// Playback uses a pull model: an AVAudioSourceNode pulls samples from a ring
/// buffer in real time. This keeps latency bounded — network hiccups produce a
/// brief silence instead of permanently growing delay, and any backlog beyond
/// the jitter-buffer target is trimmed.
///
/// Packet layout: u16 sequence, then 192 stereo sample pairs (768 bytes).
///
/// `@unchecked Sendable` because mutable state is confined to `queue` /
/// unfair-lock / `engineLifecycleLock`; NotificationCenter and Network
/// callbacks need to hop onto those without Sendable closure diagnostics.
final class AudioReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "audio-receiver")
    private let connectionsLock = NSLock()
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    private let engine = AVAudioEngine()
    private let engineLifecycleLock = NSLock()
    private var sourceNode: AVAudioSourceNode?
    private let renderFormat: AVAudioFormat

    /// Sample rate used for the local engine (Ultimate PAL-derived rate).
    private static let sampleRate: Double = 47983.0
    /// RF antenna simulation mains hum. Set to 60 for NTSC machines.
    var mainsHumFrequencyHz: Double = 50.0

    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = newValue
            applyOutputGain()
        }
    }

    /// Silences playback without stopping the stream — used in the
    /// multi-viewer grid so only one device is audible at a time.
    var muted: Bool = false {
        didSet { applyOutputGain() }
    }
    /// Independent global-route gate: when app-wide AirPlay is active, the
    /// selected receiver still feeds visualizers and the HLS encoder, but its
    /// local AVAudioEngine must be silent to avoid double playback.
    var externalOutputSuppressed: Bool = false {
        didSet { updateExternalOutputState() }
    }
    private var storedVolume: Float = 1.0

    var effectiveLocalVolume: Float {
        (muted || externalOutputSuppressed) ? 0 : storedVolume
    }

    private func applyOutputGain() {
        engine.mainMixerNode.outputVolume = effectiveLocalVolume
    }

    /// AirPlay lock uses a hard engine pause, not only mixer gain. CoreAudio
    /// can recreate a mixer at full gain during route changes, defeating a
    /// stored zero-volume setting. UDP reception and sample observers are
    /// independent of this engine and continue while it is paused.
    private func updateExternalOutputState() {
        engineLifecycleLock.lock()
        defer { engineLifecycleLock.unlock() }
        applyOutputGain()
        guard started else { return }
        if externalOutputSuppressed {
            if engine.isRunning { engine.pause() }
        } else if !engine.isRunning {
            // Discard the stale local jitter backlog accumulated while
            // AirPlay was active; resume from fresh packets.
            os_unfair_lock_lock(lock)
            readIndex = 0
            writeIndex = 0
            framesAvailable = 0
            primed = false
            os_unfair_lock_unlock(lock)
            try? engine.start()
            applyOutputGain()
        }
    }

    /// Target jitter buffer depth in seconds. Playback starts once this much
    /// audio is buffered; backlog beyond target + slack is dropped.
    private let configurationLock = NSLock()
    private var storedBufferSeconds: Double = 0.06
    var bufferSeconds: Double {
        get {
            configurationLock.lock()
            defer { configurationLock.unlock() }
            return storedBufferSeconds
        }
        set {
            configurationLock.lock()
            storedBufferSeconds = max(0.01, newValue)
            configurationLock.unlock()
        }
    }

    /// Empty / unset follows the system default output. Non-empty is a
    /// CoreAudio device UID from `AudioOutputDevices`.
    private var storedPreferredOutputUID = AudioOutputDevices.systemDefaultUID
    var preferredOutputDeviceUID: String {
        get {
            configurationLock.lock()
            defer { configurationLock.unlock() }
            return storedPreferredOutputUID
        }
        set {
            configurationLock.lock()
            let changed = storedPreferredOutputUID != newValue
            storedPreferredOutputUID = newValue
            configurationLock.unlock()
            if changed {
                pinSelectedOrDefaultOutputDevice()
            }
        }
    }

    /// Lifetime packet count for this receiver instance. Stream pickup uses
    /// a per-connect baseline rather than comparing this value with zero.
    /// Written on the receive queue; racy polling reads are fine.
    private var packetCount = 0

    var packetsReceived: Int {
        queue.sync { packetCount }
    }

    /// RF mode: filter playback like a TV speaker fed from the antenna —
    /// mono, band-limited, with a bed of static. Written from the main
    /// thread, read on the audio thread (a torn read is harmless here).
    private var storedRFAudioEnabled = false
    var rfAudioEnabled: Bool {
        get {
            configurationLock.lock()
            defer { configurationLock.unlock() }
            return storedRFAudioEnabled
        }
        set {
            configurationLock.lock()
            storedRFAudioEnabled = newValue
            configurationLock.unlock()
        }
    }

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
        stop()
        lock.deallocate()
    }

    func start(port: UInt16) async throws {
        resetForStart()
        pinSelectedOrDefaultOutputDevice()

        do {
            try startEngineLocked()
        } catch {
            // CoreAudio can refuse (error 35) when the engine is restarted
            // in quick succession — e.g. stop/start during a reconnect.
            // Yield asynchronously so @MainActor callers never freeze on a
            // Thread.sleep; one retry usually clears the transient refusal.
            try await Task.sleep(for: .milliseconds(250))
            try startEngineLocked()
        }
        started = true
        // Engine creation/restart can reset the mixer's gain to its default.
        // Reassert selection/AirPlay gates after the graph is live.
        updateExternalOutputState()

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
                self.pinSelectedOrDefaultOutputDevice()
                if !self.externalOutputSuppressed,
                   !self.engine.isRunning {
                    try? self.engine.start()
                }
                // CoreAudio may recreate the mixer as part of a route change,
                // losing its previous zero gain even though our suppression
                // flags remain true.
                self.applyOutputGain()
                if self.externalOutputSuppressed,
                   self.engine.isRunning {
                    self.engine.pause()
                }
            }
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.register(connection)
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Synchronous setup for `start` — keeps lock usage out of the async
    /// function body (Swift 6 treats NSLock / os_unfair_lock as unavailable
    /// from asynchronous contexts).
    private func resetForStart() {
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
    }

    private func startEngineLocked() throws {
        engineLifecycleLock.lock()
        defer { engineLifecycleLock.unlock() }
        try engine.start()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock()
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        connectionsLock.unlock()
        for connection in connections {
            connection.cancel()
        }
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        if started {
            engineLifecycleLock.lock()
            engine.stop()
            started = false
            engineLifecycleLock.unlock()
        }
    }

    /// Pins the engine's output unit to the user's preferred device, or the
    /// system default when none is set / the preferred device is gone —
    /// rather than trusting AVAudioEngine's automatic selection (see the
    /// `configChangeObserver` registration above).
    private func pinSelectedOrDefaultOutputDevice() {
        guard let audioUnit = engine.outputNode.audioUnit else { return }

        configurationLock.lock()
        let preferredUID = storedPreferredOutputUID
        configurationLock.unlock()

        var deviceID: AudioDeviceID
        if let preferred = AudioOutputDevices.deviceID(forUID: preferredUID) {
            deviceID = preferred
        } else if let defaultID = AudioOutputDevices.defaultOutputDeviceID() {
            deviceID = defaultID
        } else {
            logger.error("Could not resolve an output device to pin")
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
            guard let self, let connection,
                  self.isActive(connection) else { return }
            if let data {
                self.handlePacket(data)
            }
            if error == nil {
                self.receive(on: connection)
            } else {
                self.unregister(connection)
            }
        }
    }

    private func register(_ connection: NWConnection) {
        connectionsLock.lock()
        activeConnections[ObjectIdentifier(connection)] = connection
        connectionsLock.unlock()
    }

    private func unregister(_ connection: NWConnection) {
        connectionsLock.lock()
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        connectionsLock.unlock()
    }

    private func isActive(_ connection: NWConnection) -> Bool {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return activeConnections[ObjectIdentifier(connection)] === connection
    }

    private func handlePacket(_ data: Data) {
        // Ultimate audio packets contain a 2-byte sequence plus exactly
        // 192 stereo Int16 frames (768 bytes). Do not let unrelated or
        // truncated UDP traffic satisfy DeviceSession's live-stream probe.
        guard started, Self.isStructurallyValidPacket(data) else { return }
        packetCount += 1
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

        configurationLock.lock()
        let configuredBufferSeconds = storedBufferSeconds
        let configuredRFAudioEnabled = storedRFAudioEnabled
        configurationLock.unlock()
        let targetFrames = max(1, Int(configuredBufferSeconds * Self.sampleRate))
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

        if configuredRFAudioEnabled {
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
    /// - constant hiss bed + faint mains hum (50 Hz PAL / 60 Hz NTSC)
    private func applyRFFilter(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        // One-pole coefficients for the fixed stream rate.
        let lpAlpha: Float = 0.30   // ~3.3 kHz per pole at 47983 Hz
        let hpAlpha: Float = 0.958  // ~330 Hz high-pass per pole
        let humHz = mainsHumFrequencyHz > 0 ? mainsHumFrequencyHz : 50.0
        let humStep = Float(2 * Double.pi * humHz / Self.sampleRate)

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
