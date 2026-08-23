import Accelerate
import Foundation

/// Un-normalized audio evidence retained alongside the display-oriented FFT
/// bars. Unlike bars, these values are not auto-gained: KAOS can therefore
/// distinguish a genuine transient from a quiet passage that happens to be
/// scaled up for display.
struct SIDSpectrumFeatures: Equatable {
    var rms: Float = 0
    var lowBandEnergy: Float = 0
    var midBandEnergy: Float = 0
    var highBandEnergy: Float = 0
    var spectralFlux: Float = 0

    static let silence = SIDSpectrumFeatures()
}

struct SIDSpectrumFrame: Equatable {
    let bars: [Float]
    let features: SIDSpectrumFeatures
}

/// A small `vDSP`-based FFT wrapper: feeds real (mono-folded) audio samples
/// in, produces a log-frequency-spaced magnitude spectrum as a fixed number
/// of 0...1 bars. Shared by the Spectrum Analyzer (shows only the latest
/// spectrum) and Spectrogram (keeps a scrolling history of them)
/// visualization modes — both read the real post-mix Ultimate audio stream
/// via `AudioReceiver`'s sample tap, not the approximate per-voice synth.
final class SIDSpectrumAnalyzer {
    static let fftSize = 1024 // power of two
    static let barCount = 48
    /// Lowest frequency the bar scale starts at — below this is mostly
    /// inaudible/DC content not worth a bar of its own. Not private: the
    /// piano-key-labeled Spectrogram view needs the exact same mapping to
    /// know which bar index a given note's frequency falls on.
    static let minFrequency = 40.0
    /// Sample rate of the Ultimate audio stream — same constant
    /// `AudioReceiver` uses, duplicated here (rather than threaded
    /// through at call sites) since it's a fixed property of the device's
    /// stream, not something that varies per analyzer instance in
    /// practice.
    static let defaultSampleRate = 47983.0

    /// `vDSP_fft_zrip`'s packed-real-FFT output isn't normalized to a
    /// clean dBFS scale — its magnitude depends on FFT size and window
    /// function in ways that don't map to a fixed "-60...0 dB" range the
    /// way a proper dBFS meter would (an earlier fixed-range version of
    /// this pegged nearly every bar to full-red regardless of how loud the
    /// SID content actually was). Rather than hand-derive the exact
    /// absolute calibration, bars are scaled *relative to the loudest
    /// recent content* — a peak-hold-with-slow-release, the same idea a
    /// real analog VU/PPM meter uses — so the display always uses its
    /// available range and reacts to genuine level changes instead of
    /// sitting pegged at one end.
    private var runningPeakDb: Float = -60
    private static let peakDecayPerFrameDb: Float = 0.6
    private static let dynamicRangeDb: Float = 42

    /// Auto-gain, by construction, treats whatever's loudest as "loud" —
    /// so without an *absolute* floor, true silence (or just the
    /// residual noise floor of a real digital audio path — the Ultimate
    /// keeps streaming audio packets continuously whenever the stream is
    /// running, whether or not anything is actually playing) still gets
    /// rescaled relative to itself and lights up every bar, exactly as
    /// if real music were loud. This threshold is checked against the
    /// raw, pre-FFT sample RMS — which *is* meaningfully calibrated
    /// (-1...1 floats straight from 16-bit PCM), unlike the FFT's own
    /// internal magnitude units — so it's a real "is anything actually
    /// playing" check, not just another relative comparison.
    private static let silenceRMSThreshold: Float = 0.0015

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var inputBuffer: [Float] = []
    /// Log magnitudes from the prior frame for a scale-independent spectral
    /// flux calculation. This deliberately tracks the raw FFT, not bars:
    /// display auto-gain must never manufacture beat evidence.
    private var previousLogMagnitudes: [Float] = []
    private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(Self.fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Feed newly-arrived mono samples. Internally accumulates until
    /// there's enough for one FFT frame, then computes and returns a new
    /// bar spectrum (values roughly 0...1) — `nil` if not enough samples
    /// have arrived yet to fill the next frame.
    ///
    /// Always analyzes the *most recent* `fftSize` samples and discards
    /// anything older outright, rather than working through a queue of
    /// every sample ever seen. If a caller ever falls behind real-time
    /// (e.g. batches several packets' worth of audio into one `ingest`
    /// call), this keeps the spectrum reflecting *now* rather than
    /// slowly catching up on stale backlog — which is what was making
    /// the visualizations still show clear activity for a noticeable
    /// moment after playback actually stopped.
    func ingest(_ monoSamples: [Float]) -> [Float]? {
        ingestFrame(monoSamples)?.bars
    }

    /// As `ingest(_:)`, but retains raw spectral evidence needed by rhythmic
    /// consumers. A single frame is returned for the newest available audio;
    /// callers that fall behind never process a stale FFT backlog.
    func ingestFrame(_ monoSamples: [Float]) -> SIDSpectrumFrame? {
        inputBuffer.append(contentsOf: monoSamples)
        guard inputBuffer.count >= Self.fftSize else { return nil }
        let frame = Array(inputBuffer.suffix(Self.fftSize))
        inputBuffer.removeAll(keepingCapacity: true)
        return computeFrame(frame)
    }

    private func computeFrame(_ frame: [Float]) -> SIDSpectrumFrame {
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        guard rms >= Self.silenceRMSThreshold else {
            // Let the auto-gain reference relax toward the floor during
            // silence too, so playback resuming later doesn't inherit a
            // stale peak from before it stopped.
            runningPeakDb = max(runningPeakDb - Self.peakDecayPerFrameDb, -60)
            previousLogMagnitudes = []
            return SIDSpectrumFrame(
                bars: [Float](repeating: 0, count: Self.barCount),
                features: .silence)
        }

        var windowed = [Float](repeating: 0, count: Self.fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))

        var magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
        var realp = [Float](repeating: 0, count: Self.fftSize / 2)
        var imagp = [Float](repeating: 0, count: Self.fftSize / 2)
        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowedPtr in
                    windowedPtr.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: Self.fftSize / 2
                    ) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
            }
        }

        let logMagnitudes = magnitudes.map { 10 * log10(max($0, 1e-12)) }
        let flux: Float
        if previousLogMagnitudes.count == logMagnitudes.count {
            var total: Float = 0
            for index in 2..<logMagnitudes.count {
                total += max(0, logMagnitudes[index] - previousLogMagnitudes[index])
            }
            flux = total / Float(logMagnitudes.count - 2)
        } else {
            flux = 0
        }
        previousLogMagnitudes = logMagnitudes

        func bandEnergy(from lowHz: Double, to highHz: Double) -> Float {
            let low = max(1, Int(lowHz / sampleRate * Double(Self.fftSize)))
            let high = min(magnitudes.count - 1, Int(highHz / sampleRate * Double(Self.fftSize)))
            guard low <= high else { return 0 }
            var meanSquare: Float = 0
            for value in magnitudes[low...high] {
                meanSquare += value
            }
            return sqrt(meanSquare / Float(high - low + 1))
        }
        let features = SIDSpectrumFeatures(
            rms: rms,
            lowBandEnergy: bandEnergy(from: 45, to: 280),
            midBandEnergy: bandEnergy(from: 280, to: 2_200),
            highBandEnergy: bandEnergy(from: 2_200, to: 8_000),
            spectralFlux: flux)

        // Track the loudest bin this frame (skipping the first couple of
        // bins — near-DC content is often dominated by window/leakage
        // artifacts rather than audible signal) to drive the auto-gain
        // floor below.
        let framePeakMagnitude = magnitudes.dropFirst(2).max() ?? 1e-9
        let framePeakDb = 10 * log10(max(framePeakMagnitude, 1e-9))
        runningPeakDb = max(framePeakDb, runningPeakDb - Self.peakDecayPerFrameDb)
        let floorDb = runningPeakDb - Self.dynamicRangeDb

        // Log-frequency-spaced bars so bass/mid/treble each get roughly
        // proportional visual width instead of bass dominating the first
        // few linear FFT bins.
        var bars = [Float](repeating: 0, count: Self.barCount)
        let nyquist = sampleRate / 2
        for bar in 0..<Self.barCount {
            let t0 = Double(bar) / Double(Self.barCount)
            let t1 = Double(bar + 1) / Double(Self.barCount)
            let f0 = Self.minFrequency * pow(nyquist / Self.minFrequency, t0)
            let f1 = Self.minFrequency * pow(nyquist / Self.minFrequency, t1)
            let bin0 = max(0, Int((f0 / nyquist) * Double(Self.fftSize / 2)))
            let bin1 = min(Self.fftSize / 2 - 1, Int((f1 / nyquist) * Double(Self.fftSize / 2)))
            var peak: Float = 0
            for bin in bin0...max(bin0, bin1) {
                peak = max(peak, magnitudes[bin])
            }
            let db = 10 * log10(max(peak, 1e-9))
            bars[bar] = Float(max(0, min(1, (db - floorDb) / Self.dynamicRangeDb)))
        }
        return SIDSpectrumFrame(bars: bars, features: features)
    }
}
