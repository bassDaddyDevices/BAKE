import Metal
import Testing
@testable import BakeGPU

struct GPUContextTests {
    @Test func sharedBuffersAreVisibleToCPUAndGPU() async throws {
        let gpu = try GPUContext()
        let buffer = try gpu.makeSharedBuffer(floatCount: 8)
        #expect(buffer.storageMode == .shared)
        let samples = buffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0..<8 { samples[index] = Float(index) }

        try await gpu.scale(buffer, count: 8, by: 2)

        #expect(Array(UnsafeBufferPointer(start: samples, count: 8)) == [0, 2, 4, 6, 8, 10, 12, 14])
    }

    @Test func newBuffersAreZeroed() throws {
        let gpu = try GPUContext()
        let buffer = try gpu.makeSharedBuffer(floatCount: 16)
        let samples = UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float.self), count: 16)
        #expect(samples.allSatisfy { $0 == 0 })
    }

    @Test func kernelsNeverWritePastTheirRange() async throws {
        // 1,000 isn't a multiple of a threadgroup width; nothing at or after index 1,000 may change.
        let gpu = try GPUContext()
        let buffer = try gpu.makeSharedBuffer(floatCount: 1_024)
        let samples = buffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0..<1_024 { samples[index] = 1 }

        try await gpu.scale(buffer, count: 1_000, by: 3)

        let all = Array(UnsafeBufferPointer(start: samples, count: 1_024))
        #expect(all[..<1_000].allSatisfy { $0 == 3 })
        #expect(all[1_000...].allSatisfy { $0 == 1 })
    }

    @Test func offsetsTargetOneRegionOfABuffer() async throws {
        let gpu = try GPUContext()
        let buffer = try gpu.makeSharedBuffer(floatCount: 8)
        let samples = buffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0..<8 { samples[index] = 1 }

        try await gpu.scale(buffer, offset: 4, count: 4, by: 5) // e.g. the second channel only

        #expect(Array(UnsafeBufferPointer(start: samples, count: 8)) == [1, 1, 1, 1, 5, 5, 5, 5])
    }

    @Test func fractalMaskMatchesCpuReferenceAcrossPatternsDepthsAndWarp() async throws {
        #expect(MemoryLayout<FractalMaskFrame>.stride == 20)
        #expect(MemoryLayout<FractalMaskUniforms>.size == 20)

        let gpu = try GPUContext()
        let totalBins = 1_025
        let binRange = 0..<totalBins
        let sampleRate = 48_000.0
        let fftSize = 2_048
        let kernel = try FractalFilterKernel(gpu: gpu, maxFrames: 1, maxBins: totalBins, sampleRate: sampleRate, fftSize: fftSize)

        for pattern in FractalMaskPattern.allCases {
            for iterations in [1, 8, 16] {
                for warp in [0.1, 1.0, 10.0] {
                    let frame = FractalMaskFrame(
                        iterations: iterations, warp: warp, center: 0.5, q: 1.3, pattern: pattern
                    )
                    let buffer = try await kernel.run(
                        frames: [frame], binRange: binRange, totalBins: totalBins,
                        sampleRate: sampleRate, fftSize: fftSize
                    )
                    let actual = UnsafeBufferPointer(
                        start: buffer.contents().assumingMemoryBound(to: Float.self), count: totalBins
                    )
                    var failures = 0, worst: Float = 0, firstBad = -1
                    for bin in 0..<totalBins {
                        let expected = Self.reference(
                            bin: bin, sampleRate: sampleRate, fftSize: fftSize, frame: frame
                        )
                        let relativeError = expected == 0 ? abs(actual[bin]) : abs(actual[bin] - expected) / abs(expected)
                        if relativeError > 1e-5 {
                            failures += 1
                            worst = max(worst, relativeError)
                            if firstBad < 0 { firstBad = bin }
                        }
                    }
                    #expect(failures == 0, "\(pattern) depth \(iterations) warp \(warp): \(failures) bins off by up to \(worst), first at bin \(firstBad)")
                }
            }
        }
    }

    private static func reference(
        bin: Int, sampleRate: Double, fftSize: Int, frame: FractalMaskFrame
    ) -> Float {
        let x = FractalFilterKernel.position(bin: bin, sampleRate: sampleRate, fftSize: fftSize)

        var mask: Float = 1
        for generation in 1...Int(frame.iterations) {
            let scale = Float(1 << generation)
            let u = fract(abs(x - frame.center) * frame.warp * scale)
            let seed = seedValue(u, pattern: FractalMaskPattern(rawValue: frame.pattern)!)
            let texture = 0.03 + 0.97 * seed
            let resonanceBase = sin(Float.pi * fract(scale * x))
            let resonance = 1 + 3 * pow(resonanceBase, 2 * frame.q)
            mask *= texture * resonance
        }
        return mask
    }

    private static func seedValue(_ u: Float, pattern: FractalMaskPattern) -> Float {
        switch pattern {
        case .cantor:
            var value = u
            for _ in 0..<5 {
                if floor(3 * value) == 1 { return 0 }
                value = fract(3 * value)
            }
            return 1
        case .mandelbrot, .julia:
            var zx: Float = pattern == .julia ? -1.5 + 3 * u : 0
            var zy: Float = 0
            let cx: Float = pattern == .julia ? -0.8 : -2 + 2.5 * u
            let cy: Float = pattern == .julia ? 0.156 : 0.25
            for iteration in 0..<32 {
                if zx * zx + zy * zy > 4 {
                    return Float(iteration) / 32
                }
                let nextX = zx * zx - zy * zy + cx
                zy = 2 * zx * zy + cy
                zx = nextX
            }
            return 1
        case .koch:
            var sum: Float = 0
            var weight: Float = 1
            var frequency: Float = 1
            for _ in 0..<5 {
                let triangle = 1 - abs(2 * fract(frequency * u) - 1)
                sum += weight * triangle
                weight *= 0.5
                frequency *= 3
            }
            return sum * (16 / 31)
        }
    }

    private static func fract(_ value: Float) -> Float {
        value - floor(value)
    }

    @Test func outputIsFrameMajorAndBinRangesAreAddressable() async throws {
        let gpu = try GPUContext()
        let frames = [
            FractalMaskFrame(iterations: 1, warp: 1, center: 0.5, q: 0.1, pattern: .cantor),
            FractalMaskFrame(iterations: 1, warp: 1, center: 0.5, q: 0.1, pattern: .koch),
        ]
        let kernel = try FractalFilterKernel(gpu: gpu, maxFrames: 2, maxBins: 1_025, sampleRate: 48_000, fftSize: 2_048)
        let fullBuffer = try await kernel.run(
            frames: frames, binRange: 0..<1_025, totalBins: 1_025, sampleRate: 48_000, fftSize: 2_048
        )
        let full = Array(UnsafeBufferPointer(
            start: fullBuffer.contents().assumingMemoryBound(to: Float.self), count: 2 * 1_025
        ))
        let buffer = try await kernel.run(
            frames: frames, binRange: 7..<23, totalBins: 1_025, sampleRate: 48_000, fftSize: 2_048
        )
        let actual = UnsafeBufferPointer(
            start: buffer.contents().assumingMemoryBound(to: Float.self), count: 32
        )
        let expected = (0..<2).flatMap { frame in (7..<23).map { full[frame * 1_025 + $0] } }
        #expect(Array(actual) == expected)
    }
}
