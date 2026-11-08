import Accelerate
import Foundation
import Metal
import Testing
@testable import BakeGPU

struct ResidualExplosionKernelTests {
    /// Runs the GPU kernel over planar shared buffers, calling `process` once per range.
    private func renderOnGPU(
        _ input: [[Float]], settings: ResidualExplosionSettings, oversampling: Int = 1,
        modulation: ResidualExplosionModulation? = nil, ranges: [Range<Int>]? = nil
    ) async throws -> [[Float]] {
        let gpu = try GPUContext()
        let frames = input[0].count
        let channels = input.count
        let inputBuffer = try gpu.makeSharedBuffer(floatCount: frames * channels)
        let outputBuffer = try gpu.makeSharedBuffer(floatCount: frames * channels)
        let inputSamples = inputBuffer.contents().assumingMemoryBound(to: Float.self)
        for (channel, samples) in input.enumerated() {
            for (frame, sample) in samples.enumerated() {
                inputSamples[channel * frames + frame] = sample
            }
        }
        let kernel = try ResidualExplosionKernel(gpu: gpu, settings: settings, channels: channels, oversampling: oversampling, modulation: modulation)
        for range in ranges ?? [0..<frames] {
            try await kernel.process(
                input: inputBuffer, inputChannelStride: frames,
                output: outputBuffer, outputChannelStride: frames, frames: range
            )
        }
        let output = outputBuffer.contents().assumingMemoryBound(to: Float.self)
        return (0..<channels).map { Array(UnsafeBufferPointer(start: output + $0 * frames, count: frames)) }
    }

    /// Seeded noise at ±`amplitude`, per channel.
    private func noise(frames: Int = 10_000, channels: Int = 2, amplitude: Float = 1) -> [[Float]] {
        var seed: UInt32 = 99
        return (0..<channels).map { _ in
            (0..<frames).map { _ in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return amplitude * (Float(seed >> 8) / Float(1 << 23) - 1)
            }
        }
    }

    /// 777-frame ranges covering `frames`.
    private func chunks(_ frames: Int) -> [Range<Int>] {
        stride(from: 0, to: frames, by: 777).map { $0..<min($0 + 777, frames) }
    }

    @Test func layoutsMatchTheShader() {
        #expect(MemoryLayout<ResidualFrame>.stride == 28)
        #expect(MemoryLayout<ResidualUniforms>.size == 28)
        #expect(MemoryLayout<ResidualOversampledUniforms>.size == 48)
    }

    @Test func severityMapsPerMode() {
        let gentle = ResidualExplosionSettings(severity: 0).frame
        #expect(gentle.levels == 32_768)
        #expect(gentle.inverseLevels == Float(1.0 / 32_768))
        #expect(gentle.threshold == Float(pow(10, -72.0 / 20)))
        let harsh = ResidualExplosionSettings(severity: 1).frame
        #expect(harsh.levels == 1)
        #expect(harsh.threshold == Float(pow(10, -6.0 / 20)))
        #expect(ResidualExplosionSettings(severity: 0.5).frame.levels == Float(pow(2, 7.5)))
        #expect(ResidualExplosionSettings(residualGainDecibels: 18).frame.gain == Float(pow(10, 18.0 / 20)))
        #expect(ResidualExplosionSettings(mode: .sparsify).frame.mode == 1)
        let clamped = ResidualExplosionSettings(severity: 3, residualGainDecibels: 90, body: -1, mix: 2).frame
        #expect(clamped.levels == 1)
        #expect(clamped.gain == 1_000)
        #expect(clamped.body == 0)
        #expect(clamped.mix == 1)
    }

    @Test(arguments: [ResidualExplosionMode.collapse, .sparsify])
    func matchesTheReference(mode: ResidualExplosionMode) async throws {
        let input = noise()
        for severity in [0.3, 0.8] {
            for gain in [0.0, 18, 60] {
                for body in [0.0, 1] {
                    let settings = ResidualExplosionSettings(mode: mode, severity: severity, residualGainDecibels: gain, body: body, mix: 0.5)
                    let output = try await renderOnGPU(input, settings: settings)
                    let frame = settings.frame
                    for channel in 0..<2 {
                        let worst = zip(output[channel], input[channel]).map { abs($0 - ResidualExplosionReference.sample($1, frame)) }.max() ?? 0
                        #expect(worst < 1e-6, "\(mode) severity \(severity) gain \(gain) body \(body)")
                    }
                }
            }
        }
    }

    @Test func bodyOneAndNoGainIsNearlyTheInput() async throws {
        let input = noise()
        let output = try await renderOnGPU(input, settings: ResidualExplosionSettings(severity: 0.5, residualGainDecibels: 0, body: 1))
        for channel in 0..<2 {
            #expect(zip(output[channel], input[channel]).allSatisfy { abs($0 - $1) < 1e-6 })
        }
    }

    @Test func collapseAtOneBitSolosTheRoundingError() async throws {
        let input = noise()
        let output = try await renderOnGPU(input, settings: ResidualExplosionSettings(severity: 1, residualGainDecibels: 0, body: 0))
        for channel in 0..<2 {
            #expect(zip(output[channel], input[channel]).allSatisfy { abs($0 - tanh($1 - $1.rounded())) < 1e-6 })
        }
    }

    @Test func sparsifyResidualIsTheQuietPart() async throws {
        let input = noise(amplitude: 0.05)
        let settings = ResidualExplosionSettings(mode: .sparsify, severity: 0.5, residualGainDecibels: 0, body: 0)
        let threshold = settings.frame.threshold
        let output = try await renderOnGPU(input, settings: settings)
        for channel in 0..<2 {
            for (y, x) in zip(output[channel], input[channel]) {
                if abs(x) >= threshold {
                    #expect(y == 0)
                } else {
                    #expect(abs(y - tanh(x)) < 1e-6)
                }
            }
        }
        // The noise straddles the −39 dB threshold, so both branches ran.
        #expect(input[0].contains { abs($0) < threshold } && input[0].contains { abs($0) >= threshold })
    }

    @Test(arguments: [ResidualExplosionMode.collapse, .sparsify])
    func residualIsCeilinged(mode: ResidualExplosionMode) async throws {
        let output = try await renderOnGPU(noise(), settings: ResidualExplosionSettings(mode: mode, severity: 0.7, residualGainDecibels: 60, body: 0))
        #expect(output.joined().allSatisfy { abs($0) <= 1 })
    }

    @Test func mixZeroIsTheInput() async throws {
        let input = noise()
        #expect(try await renderOnGPU(input, settings: ResidualExplosionSettings(residualGainDecibels: 60, mix: 0)) == input)
    }

    /// Mode switches every 500 frames; Severity ramps across the file; Body and gain move too.
    private let moving = ResidualExplosionModulation { frame in
        ResidualExplosionSettings(
            mode: (frame / 500) % 2 == 0 ? .collapse : .sparsify,
            severity: Double(frame) / 10_000,
            residualGainDecibels: 30 + 20 * sin(Double(frame) / 300),
            body: 0.5 + 0.5 * cos(Double(frame) / 700),
            mix: 0.8
        )
    }

    @Test func chunksOf777MatchOneRender() async throws {
        let input = noise()
        let settings = ResidualExplosionSettings()
        let whole = try await renderOnGPU(input, settings: settings, modulation: moving)
        #expect(try await renderOnGPU(input, settings: settings, modulation: moving, ranges: chunks(10_000)) == whole)
        let still = try await renderOnGPU(input, settings: settings)
        #expect(try await renderOnGPU(input, settings: settings, ranges: chunks(10_000)) == still)
    }

    @Test func modulatedMatchesTheReference() async throws {
        let input = noise()
        let output = try await renderOnGPU(input, settings: ResidualExplosionSettings(), modulation: moving, ranges: chunks(10_000))
        for channel in 0..<2 {
            for frame in 0..<10_000 {
                let expected = ResidualExplosionReference.sample(input[channel][frame], moving.settingsAt(frame).frame)
                #expect(abs(output[channel][frame] - expected) < 1e-6, "frame \(frame)")
            }
        }
    }

    // MARK: Oversampling

    @Test(arguments: [2, 8, 32])
    func oversamplingTapsAreUnityGainAndSymmetric(factor: Int) {
        let taps = OversamplingFilter.taps(factor: factor)
        #expect(taps.count == 64 * factor + 1)
        #expect(abs(taps.reduce(0, +) - 1) < 1e-5)
        #expect(zip(taps, taps.reversed()).allSatisfy { $0 == $1 })
    }

    @Test(arguments: [ResidualExplosionMode.collapse, .sparsify])
    func oversampledMatchesTheReference(mode: ResidualExplosionMode) async throws {
        let input = noise(frames: 3_000, amplitude: 0.7)
        let settings = ResidualExplosionSettings(mode: mode, severity: 0.6, residualGainDecibels: 40, body: 0.5, mix: 0.8)
        let output = try await renderOnGPU(input, settings: settings, oversampling: 4)
        for channel in 0..<2 {
            let expected = ResidualExplosionReference.oversampled(input[channel], factor: 4) { _ in settings.frame }
            let errors = zip(output[channel], expected).map { abs($0 - $1) }
            if mode == .sparsify {
                #expect((errors.max() ?? 1) < 1e-5)
            } else {
                // Float sums on the GPU against double sums here: an upsampled sample sitting on a quantiser
                // step can round the other way. One flip moves a frame by at most ~gain / L spread over the
                // filter (measured ≤ 0.21 at 4×), so allow a few outliers but never a large one.
                let close = errors.filter { $0 < 1e-4 }.count
                #expect(Double(close) >= 0.97 * Double(errors.count))
                #expect((errors.max() ?? 0) < 0.5)
            }
        }
    }

    @Test func oversampledChunksMatchOneRender() async throws {
        let input = noise()
        let settings = ResidualExplosionSettings()
        let whole = try await renderOnGPU(input, settings: settings, oversampling: 8, modulation: moving)
        #expect(try await renderOnGPU(input, settings: settings, oversampling: 8, modulation: moving, ranges: chunks(10_000)) == whole)
        let still = try await renderOnGPU(input, settings: settings, oversampling: 8)
        #expect(try await renderOnGPU(input, settings: settings, oversampling: 8, ranges: chunks(10_000)) == still)
    }

    @Test func oversampledMixZeroIsTheInput() async throws {
        let input = noise()
        #expect(try await renderOnGPU(input, settings: ResidualExplosionSettings(residualGainDecibels: 60, mix: 0), oversampling: 8) == input)
    }

    /// Fraction of a signal's energy (below Nyquist) that is not at a harmonic of `bin`.
    private func inharmonicFraction(_ signal: [Float], bin: Int) -> Double {
        let n = signal.count
        let log2n = vDSP_Length(log2(Double(n)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: n / 2)
        var imaginary = [Float](repeating: 0, count: n / 2)
        var harmonic = 0.0
        var total = 0.0
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                signal.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                for k in 1..<(n / 2) {
                    let power = Double(re[k] * re[k] + im[k] * im[k])
                    total += power
                    if k % bin == 0 { harmonic += power }
                }
            }
        }
        return total > 0 ? 1 - harmonic / total : 0
    }

    @Test(arguments: [ResidualExplosionMode.collapse, .sparsify])
    func oversamplingCutsAliasing(mode: ResidualExplosionMode) async throws {
        // A coherent ~997 Hz sine: every true harmonic lands on a multiple of bin 1361, aliases don't.
        let frames = 65_536
        let bin = 1_361
        let tone = [(0..<frames).map { Float(0.5 * sin(2 * Double.pi * Double(bin) * Double($0) / Double(frames))) }]
        // The aliasing-dominated settings measured with an ideal 8× filter: Collapse needs +60 dB (at +40 dB
        // its residual is genuinely noise-like, ~80% inharmonic even ideally), Sparsify +40 dB.
        let gain = mode == .collapse ? 60.0 : 40
        let settings = ResidualExplosionSettings(mode: mode, severity: 0.6, residualGainDecibels: gain, body: 0)
        let plain = inharmonicFraction(try await renderOnGPU(tone, settings: settings)[0], bin: bin)
        let oversampled = inharmonicFraction(try await renderOnGPU(tone, settings: settings, oversampling: 8)[0], bin: bin)
        #expect(plain > 0.8)
        #expect(oversampled < 0.5 * plain)
    }
}
