import Foundation
@testable import BakeGPU

/// The Residual Explosion shader's formula on the CPU, used only to check the GPU kernel.
/// Same operations as ResidualExplosion.metal.
enum ResidualExplosionReference {
    static func sample(_ x: Float, _ f: ResidualFrame) -> Float {
        let simplified: Float = f.mode == 0
            ? (x * f.levels).rounded() * f.inverseLevels
            : (abs(x) < f.threshold ? 0 : x)
        let wet = f.body * simplified + tanh(f.gain * (x - simplified))
        return f.mix * wet + (1 - f.mix) * x
    }
}

extension ResidualExplosionReference {
    /// The node's wet signal before Mix, for one upsampled sample.
    static func wet(_ x: Float, _ f: ResidualFrame) -> Float {
        let simplified: Float = f.mode == 0
            ? (x * f.levels).rounded() * f.inverseLevels
            : (abs(x) < f.threshold ? 0 : x)
        return f.body * simplified + tanh(f.gain * (x - simplified))
    }

    /// Oversampled render of one channel, as the CPU oversampler does it (double sums): upsample with
    /// the shared Kaiser filter, shape at the high rate, filter and decimate, then Mix at the base rate.
    static func oversampled(_ input: [Float], factor: Int, frame: (Int) -> ResidualFrame) -> [Float] {
        let taps = OversamplingFilter.taps(factor: factor)
        let length = taps.count
        let center = length / 2
        let frames = input.count
        func floorDivide(_ value: Int, _ divisor: Int) -> Int {
            let quotient = value / divisor
            return (value % divisor != 0 && value < 0) ? quotient - 1 : quotient
        }
        func inputAt(_ index: Int) -> Float { index >= 0 && index < frames ? input[index] : 0 }
        // high[j] is upsampled index m = j − center.
        let highCount = (frames - 1) * factor + 2 * center + 1
        let high = (0..<highCount).map { j -> Float in
            let m = j - center
            let lowest = floorDivide(m + center - (length - 1) + factor - 1, factor)
            let highest = floorDivide(m + center, factor)
            var sum = 0.0
            if lowest <= highest {
                for b in lowest...highest {
                    sum += Double(taps[m + center - b * factor]) * Double(inputAt(b))
                }
            }
            return wet(Float(sum * Double(factor)), frame(max(0, floorDivide(m, factor))))
        }
        return (0..<frames).map { i in
            var sum = 0.0
            for k in 0..<length {
                sum += Double(taps[k]) * Double(high[i * factor + 2 * center - k])
            }
            let mix = frame(i).mix
            return mix * Float(sum) + (1 - mix) * input[i]
        }
    }
}
