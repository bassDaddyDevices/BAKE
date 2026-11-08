import Foundation
import Metal
import Testing
@testable import BakeGPU

struct ResonatorKernelTests {
    /// Runs the GPU kernel over planar shared buffers, calling `process` once per range.
    private func renderOnGPU(
        _ input: [[Float]], settings: ResonatorSettings, sampleRate: Double = 48_000, ranges: [Range<Int>]? = nil
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
        let kernel = try ResonatorKernel(gpu: gpu, settings: settings, sampleRate: sampleRate, channels: channels)
        for range in ranges ?? [0..<frames] {
            try await kernel.process(
                input: inputBuffer, inputChannelStride: frames,
                output: outputBuffer, outputChannelStride: frames, frames: range
            )
        }
        let output = outputBuffer.contents().assumingMemoryBound(to: Float.self)
        return (0..<channels).map { Array(UnsafeBufferPointer(start: output + $0 * frames, count: frames)) }
    }

    /// A short seeded noise burst followed by silence, per channel.
    private func burst(frames: Int, channels: Int) -> [[Float]] {
        var seed: UInt32 = 99
        return (0..<channels).map { _ in
            (0..<frames).map { frame in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return frame < 200 ? Float(seed >> 8) / Float(1 << 24) - 0.5 : 0
            }
        }
    }

    @Test func uniformLayoutsMatchTheShader() {
        #expect(MemoryLayout<ResonatorUniforms>.size == 56)
        #expect(MemoryLayout<ResonatorBandParameters>.stride == 12)
    }

    @Test func mixZeroPassesTheInputThrough() async throws {
        let input = burst(frames: 6_000, channels: 2)
        let output = try await renderOnGPU(input, settings: ResonatorSettings(mix: 0))
        #expect(output == input)
    }

    @Test func halfMixMatchesTheReference() async throws {
        let input = burst(frames: 6_000, channels: 2)
        let settings = ResonatorSettings(rootHz: 110, decaySeconds: 1, mix: 0.5)
        let gpu = try await renderOnGPU(input, settings: settings)
        let cpu = ResonatorReference.render(input, settings: settings, sampleRate: 48_000)
        for channel in 0..<2 {
            let worst = zip(gpu[channel], cpu[channel]).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < 1e-3, "channel \(channel) differs by \(worst)")
        }
    }

    @Test func gpuMatchesTheCPUReference() async throws {
        // 6,000 frames crosses the 4,096-frame sub-chunk boundary.
        let input = burst(frames: 6_000, channels: 2)
        let settings = ResonatorSettings(rootHz: 110, decaySeconds: 1, damping: 0.2, saturation: 0.3)

        let gpu = try await renderOnGPU(input, settings: settings)
        let cpu = ResonatorReference.render(input, settings: settings, sampleRate: 48_000)

        for channel in 0..<2 {
            let worst = zip(gpu[channel], cpu[channel]).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < 1e-3, "channel \(channel) differs by \(worst)")
        }
    }

    @Test func chunkingDoesNotChangeTheResult() async throws {
        let input = burst(frames: 10_000, channels: 1)
        let settings = ResonatorSettings(rootHz: 220, decaySeconds: 2)

        let whole = try await renderOnGPU(input, settings: settings)
        let pieces = stride(from: 0, to: 10_000, by: 999).map { $0..<min($0 + 999, 10_000) }
        let chunked = try await renderOnGPU(input, settings: settings, ranges: pieces)

        #expect(chunked == whole)
    }

    /// Power at `frequency` over a Hann-windowed signal (Goertzel). The window keeps leakage
    /// from neighbouring energy out of the measurement.
    private func power(of signal: [Float], at frequency: Double, sampleRate: Double = 48_000) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        var s1 = 0.0
        var s2 = 0.0
        for (index, sample) in signal.enumerated() {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(signal.count - 1))
            let s = Double(sample) * hann + 2 * cos(w) * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
    }

    private func impulseResponse(root: Double) async throws -> [Float] {
        var impulse = [Float](repeating: 0, count: 4_800)
        impulse[0] = 1
        let output = try await renderOnGPU([impulse], settings: ResonatorSettings(rootHz: root, decaySeconds: 1))[0]
        return Array(output.dropFirst()) // drop the dry impulse itself
    }

    @Test func ringsAtTheTunedHarmonics() async throws {
        let response = try await impulseResponse(root: 480)
        let harmonics = [480.0, 960, 1_440].map { power(of: response, at: $0) }
        let between = [240.0, 360, 600, 720, 1_200].map { power(of: response, at: $0) }
        // Every harmonic must dwarf every in-between frequency.
        #expect(harmonics.min()! > 100 * between.max()!)
    }

    @Test func doesNotBuildUpADCOffset() async throws {
        // A feedback comb also resonates at 0 Hz; the in-loop DC blocker must keep it near zero.
        let response = try await impulseResponse(root: 480)
        let mean = response.reduce(0, +) / Float(response.count)
        #expect(abs(mean) < 1e-3)
    }

    @Test func largeBandCountsStayFinite() async throws {
        let input = burst(frames: 5_000, channels: 1)
        let output = try await renderOnGPU(input, settings: ResonatorSettings(rootHz: 20, decaySeconds: 5, bands: 1_024))[0]
        #expect(output.allSatisfy { $0.isFinite && abs($0) < 10 })
        #expect(output.contains { $0 != 0 })
    }
}
