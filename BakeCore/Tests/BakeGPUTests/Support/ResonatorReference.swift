import Foundation
@testable import BakeGPU

/// Straightforward single-threaded Resonator, used only to check the GPU kernel.
/// Same math and operation order as Resonator.metal.
enum ResonatorReference {
    static func render(_ input: [[Float]], settings: ResonatorSettings, sampleRate: Double) -> [[Float]] {
        let bands = ResonatorTuning.bands(for: settings, sampleRate: sampleRate)
        let capacity = ResonatorTuning.delayCapacity(for: bands)
        let normalization = 1 / Float(max(bands.filter(\.isActive).count, 1))
        let damping = Float(settings.damping)
        let saturation = Float(settings.saturation)
        let wet = Float(min(max(settings.mix, 0), 1))

        return input.map { x in
            var sum = [Float](repeating: 0, count: x.count)
            for band in bands where band.isActive {
                var line = [Float](repeating: 0, count: capacity)
                var write = 0
                var lowpass: Float = 0
                var dcInput: Float = 0
                var dcOutput: Float = 0
                for i in 0..<x.count {
                    let readPosition = Float(write) + Float(capacity) - band.delay
                    let i0 = Int(readPosition) % capacity
                    let i1 = (i0 + 1) % capacity
                    let fraction = readPosition - readPosition.rounded(.down)
                    let delayed = line[i0] + (line[i1] - line[i0]) * fraction
                    lowpass = delayed + (lowpass - delayed) * damping
                    let looped = lowpass * band.feedback
                    // DC blocker: a feedback comb also resonates at 0 Hz; keep it from building up.
                    let blocked = looped - dcInput + ResonatorTuning.dcBlockerPole * dcOutput
                    dcInput = looped
                    dcOutput = blocked
                    let feedback = blocked + (tanh(blocked) - blocked) * saturation
                    let y = x[i] + feedback
                    line[write] = y
                    write = (write + 1) % capacity
                    sum[i] += y
                }
            }
            return zip(x, sum).map { dry, resonance in dry * (1 - wet) + resonance * normalization * wet }
        }
    }
}
