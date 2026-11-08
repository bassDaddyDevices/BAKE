import Foundation

/// The oversampling filter the CPU nodes use (`designTaps` in BakeDSP/Oversampling.h), for GPU kernels:
/// a centred Kaiser-windowed sinc at the oversampled rate, 64 taps per phase, unity DC gain. Same
/// constants and operations, so oversampled nodes sound alike on both engines (a parity test checks).
public enum OversamplingFilter {
    public static let maxFactor = 256

    public static func taps(factor: Int) -> [Float] {
        let factor = min(max(factor, 1), maxFactor)
        let cutoffFraction = 0.84 // of the base-rate Nyquist
        let kaiserBeta = 8.0
        let length = 64 * factor + 1
        let center = length / 2
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0
            var term = 1.0
            for k in 1..<40 {
                term *= (x / (2.0 * Double(k))) * (x / (2.0 * Double(k)))
                sum += term
            }
            return sum
        }
        var taps = [Float](repeating: 0, count: length)
        var sum = 0.0
        for k in 0..<length {
            let t = Double(k - center) / Double(factor)
            let x = Double.pi * cutoffFraction * t
            let sinc = k == center ? 1.0 : sin(x) / x
            let r = Double(k - center) / Double(center)
            let window = besselI0(kaiserBeta * max(0, 1 - r * r).squareRoot()) / besselI0(kaiserBeta)
            taps[k] = Float(sinc * window)
            sum += Double(taps[k])
        }
        for k in 0..<length {
            taps[k] = Float(Double(taps[k]) / sum)
        }
        return taps
    }
}
