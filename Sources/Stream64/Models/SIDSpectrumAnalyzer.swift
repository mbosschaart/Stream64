import Accelerate
import Foundation

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
    /// inaudible/DC content not worth a bar of its own.
    private static let minFrequency = 40.0

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var inputBuffer: [Float] = []
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
    func ingest(_ monoSamples: [Float]) -> [Float]? {
        inputBuffer.append(contentsOf: monoSamples)
        guard inputBuffer.count >= Self.fftSize else { return nil }
        let frame = Array(inputBuffer.prefix(Self.fftSize))
        inputBuffer.removeFirst(Self.fftSize)
        return Self.computeBars(frame, window: window, fftSetup: fftSetup, log2n: log2n, sampleRate: sampleRate)
    }

    private static func computeBars(
        _ frame: [Float], window: [Float], fftSetup: FFTSetup, log2n: vDSP_Length, sampleRate: Double
    ) -> [Float] {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowedPtr in
                    windowedPtr.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: fftSize / 2
                    ) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Log-frequency-spaced bars so bass/mid/treble each get roughly
        // proportional visual width instead of bass dominating the first
        // few linear FFT bins.
        var bars = [Float](repeating: 0, count: barCount)
        let nyquist = sampleRate / 2
        for bar in 0..<barCount {
            let t0 = Double(bar) / Double(barCount)
            let t1 = Double(bar + 1) / Double(barCount)
            let f0 = minFrequency * pow(nyquist / minFrequency, t0)
            let f1 = minFrequency * pow(nyquist / minFrequency, t1)
            let bin0 = max(0, Int((f0 / nyquist) * Double(fftSize / 2)))
            let bin1 = min(fftSize / 2 - 1, Int((f1 / nyquist) * Double(fftSize / 2)))
            var peak: Float = 0
            for bin in bin0...max(bin0, bin1) {
                peak = max(peak, magnitudes[bin])
            }
            // Rough dB scale, normalized into 0...1 for easy rendering —
            // not calibrated to any absolute reference level.
            let db = 10 * log10(max(peak, 1e-9))
            bars[bar] = Float(max(0, min(1, (db + 60) / 60)))
        }
        return bars
    }
}
