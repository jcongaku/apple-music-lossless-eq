import Foundation
import Accelerate
import Synchronization

/// Real-time spectrum analyzer for the EQ window. The audio engine pushes
/// post-EQ output samples in via `append` (audio thread, lock-free ring write);
/// a 24 fps timer on the main run loop runs a windowed FFT and publishes
/// log-spaced magnitudes, smoothed across neighbouring bins and over time so
/// the curve reads as a soft envelope rather than spiky bars. Because it
/// analyses the processed output, the displayed spectrum reflects EQ live.
final class SpectrumAnalyzer: ObservableObject, @unchecked Sendable {
    /// Normalised magnitudes (0…1), one per display bin, log-spaced 20 Hz–20 kHz.
    @Published private(set) var levels: [Float]

    /// Updated by the engine when the device sample rate changes (for bin→freq).
    var sampleRate: Double = 48_000

    let binCount = 64
    private let fftSize = 2048
    private let halfSize = 1024
    private static let ringSize = 65_536 // power of two; prevents reader overrun

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var hann: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]
    private var raw: [Float]
    private var smoothed: [Float]

    private let ring: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private var timer: Timer?

    init() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: fftSize)
        realp = [Float](repeating: 0, count: halfSize)
        imagp = [Float](repeating: 0, count: halfSize)
        magnitudes = [Float](repeating: 0, count: halfSize)
        raw = [Float](repeating: 0, count: binCount)
        smoothed = [Float](repeating: 0, count: binCount)
        ring = .allocate(capacity: Self.ringSize)
        ring.initialize(repeating: 0, count: Self.ringSize)
        levels = [Float](repeating: 0, count: binCount)
    }

    deinit {
        timer?.invalidate()
        ring.deinitialize(count: Self.ringSize)
        ring.deallocate()
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Audio thread: copy samples into the ring buffer. No allocation/locks.
    func append(_ samples: UnsafePointer<Float>, count: Int) {
        var w = writeIndex.load(ordering: .relaxed)
        let mask = Self.ringSize - 1
        for i in 0..<count {
            ring[w & mask] = samples[i]
            w &+= 1
        }
        writeIndex.store(w, ordering: .releasing)
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        smoothed = [Float](repeating: 0, count: binCount)
        levels = [Float](repeating: 0, count: binCount)
    }

    private func tick() {
        let end = writeIndex.load(ordering: .acquiring)
        let mask = Self.ringSize - 1
        for i in 0..<fftSize {
            windowed[i] = ring[(end - fftSize + i) & mask]
        }
        vDSP_vmul(windowed, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        let nyquist = sampleRate / 2
        let scale = 2.0 / Float(fftSize)
        for i in 0..<binCount {
            let t = Double(i) / Double(binCount - 1)
            let freq = 20.0 * pow(1000.0, t)                 // 20 Hz … 20 kHz
            var bin = Int((freq / nyquist) * Double(halfSize))
            bin = min(max(bin, 1), halfSize - 1)
            let db = 20.0 * log10(magnitudes[bin] * scale + 1e-7)
            raw[i] = Float(min(max((db + 80.0) / 80.0, 0), 1))   // −80…0 dB → 0…1
        }
        // Round off sharp peaks: blend each bin with its neighbours (a [1,2,1]
        // kernel), then ease toward it with a gentle attack and slow release so
        // the spectrum reads as a soft envelope rather than spiky bars.
        for i in 0..<binCount {
            let lo = max(0, i - 1), hi = min(binCount - 1, i + 1)
            let blended = (raw[lo] + 2 * raw[i] + raw[hi]) / 4
            let coeff: Float = blended > smoothed[i] ? 0.45 : 0.15
            smoothed[i] = smoothed[i] * (1 - coeff) + blended * coeff
        }
        levels = smoothed
    }
}
