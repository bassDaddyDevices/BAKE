import BakeDSP
import BakeGPU
import Foundation
import Metal
import Testing

/// The GPU follower against the CPU reference (otftGainColumns): same arithmetic in floats, so a few thousandths of a dB.
struct OtftGPUTests {
    private func levels(frames: Int, units: Int) -> [Float] {
        var seed: UInt32 = 12_345
        return (0..<(frames * units)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return -90 + Float(seed >> 8) / Float(1 << 24) * 90
        }
    }

    private func frameTable(_ frames: Int) -> [bake.dsp.OtftFrameParams] {
        (0..<frames).map { index in
            var frame = bake.dsp.OtftFrameParams()
            frame.downThreshold = -30 + Float(index % 7)
            frame.downSlope = 0.75
            frame.upThreshold = -60 - Float(index % 5)
            frame.upSlope = 0.5
            frame.maxBoost = 12
            frame.attackMs = 5 + Float(index % 11)
            frame.releaseMs = 80 + Float(index % 13)
            return frame
        }
    }

    private func check(anticipating: Bool, smoothFrames: Int) async throws {
        guard let gpu = try? GPUContext() else { return }   // no Metal device: nothing to compare
        let frames = 220, units = 300
        let input = levels(frames: frames, units: units)
        let params = frameTable(frames)
        let timeScale = (0..<units).map { 0.5 + Float($0 % 9) * 0.25 }
        let offset = (0..<units).map { Float($0 % 6) - 3 }
        var envelope = bake.dsp.OtftEnvelope()
        envelope.hopMilliseconds = 21.3
        envelope.kneeDb = 6
        envelope.anticipating = anticipating ? 1 : 0
        envelope.smoothFrames = UInt32(smoothFrames)

        var reference = input
        var column = [Float](repeating: 0, count: frames)
        bake.dsp.otftGainColumns(params, frames, units, 0, units, timeScale, offset, envelope, &reference, &column)

        let surface = try gpu.makeSharedBuffer(floatCount: frames * units)
        surface.contents().bindMemory(to: Float.self, capacity: frames * units).update(from: input, count: input.count)
        let scratch = smoothFrames > 0 ? try gpu.makeSharedBuffer(floatCount: frames * units) : nil
        let kernel = try OtftKernel(gpu: gpu, maxFrames: frames, maxUnits: units)
        let gpuFrames = params.map {
            OtftGPUFrame(
                downThreshold: $0.downThreshold, downSlope: $0.downSlope, upThreshold: $0.upThreshold, upSlope: $0.upSlope,
                maxBoost: $0.maxBoost, attackMs: $0.attackMs, releaseMs: $0.releaseMs
            )
        }
        let result = try await kernel.run(
            surface: surface, scratch: scratch, frames: gpuFrames, units: units, timeScale: timeScale, offsetDb: offset,
            hopMilliseconds: 21.3, kneeDb: 6, anticipating: anticipating, smoothFrames: smoothFrames
        )
        let values = result.contents().bindMemory(to: Float.self, capacity: frames * units)
        var worst: Float = 0
        for index in 0..<(frames * units) { worst = max(worst, abs(values[index] - reference[index])) }
        #expect(worst < 0.02, "worst difference \(worst) dB")
    }

    @Test func layoutsMatchTheShader() {
        #expect(MemoryLayout<OtftGPUFrame>.stride == 32)
        #expect(MemoryLayout<bake.dsp.OtftFrameParams>.stride == 32)
    }

    @Test func causalFollowerMatchesTheCPU() async throws { try await check(anticipating: false, smoothFrames: 0) }

    @Test func anticipatingFollowerMatchesTheCPU() async throws { try await check(anticipating: true, smoothFrames: 0) }

    @Test func timeSmoothingMatchesTheCPU() async throws { try await check(anticipating: false, smoothFrames: 3) }
}
