import BakeDSP
import Foundation
import Testing

/// `bake.dsp.fft` (Accelerate on the Mac) against the portable radix-2 reference.
struct FftTests {
    private func signal(_ size: Int, seed: UInt64) -> (real: [Double], imaginary: [Double]) {
        var state = seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
        return ((0..<size).map { _ in next() }, (0..<size).map { _ in next() })
    }

    private func twiddles(_ size: Int) -> (cosines: [Double], sines: [Double]) {
        var cosines = [Double](repeating: 0, count: size / 2)
        var sines = [Double](repeating: 0, count: size / 2)
        bake.dsp.fftTwiddles(size, &cosines, &sines)
        return (cosines, sines)
    }

    private func transform(_ input: (real: [Double], imaginary: [Double]), reference: Bool) -> (real: [Double], imaginary: [Double]) {
        let size = input.real.count
        let table = twiddles(size)
        var real = input.real
        var imaginary = input.imaginary
        if reference {
            bake.dsp.fftReference(&real, &imaginary, size, table.cosines, table.sines)
        } else {
            bake.dsp.fft(&real, &imaginary, size, table.cosines, table.sines)
        }
        return (real, imaginary)
    }

    @Test func theMacBuildRunsOnAccelerate() {
        #expect(bake.dsp.fftUsesAccelerate())
    }

    @Test(arguments: [2, 4, 8, 16, 64, 256, 4_096, 65_536, 524_288])
    func matchesTheReference(size: Int) {
        let input = signal(size, seed: UInt64(size))
        let fast = transform(input, reference: false)
        let slow = transform(input, reference: true)
        let scale = slow.real.map(abs).max() ?? 1
        let worst = zip(fast.real + fast.imaginary, slow.real + slow.imaginary).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-11 * scale, "size \(size): worst difference \(worst)")
    }

    @Test func aSineLandsInItsBin() {
        let size = 4_096
        let real = (0..<size).map { cos(2 * Double.pi * 100 * Double($0) / Double(size)) }
        let result = transform((real, [Double](repeating: 0, count: size)), reference: false)
        #expect(abs(result.real[100] - Double(size) / 2) < 1e-9)
        #expect(abs(result.real[size - 100] - Double(size) / 2) < 1e-9)
        #expect(abs(result.imaginary[100]) < 1e-9)
    }

    @Test(arguments: [64, 4_096, 131_072])
    func inverseGivesTheInputBack(size: Int) {
        let input = signal(size, seed: 3)
        let table = twiddles(size)
        var real = input.real
        var imaginary = input.imaginary
        bake.dsp.fft(&real, &imaginary, size, table.cosines, table.sines)
        bake.dsp.inverseFft(&real, &imaginary, size, table.cosines, table.sines)
        let worst = zip(real + imaginary, input.real + input.imaginary).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-12)
    }

    @Test func theResultDoesNotDependOnWhereTheArraysSit() {
        // The engine hands the transform arrays at different offsets and alignments; the bits must not change.
        let size = 4_096
        let input = signal(size, seed: 9)
        let table = twiddles(size)
        let baseline = transform(input, reference: false)
        for offset in 0..<4 {
            var realStorage = [Double](repeating: 0, count: size + 8)
            var imaginaryStorage = [Double](repeating: 0, count: size + 8)
            for index in 0..<size {
                realStorage[offset + index] = input.real[index]
                imaginaryStorage[offset + index] = input.imaginary[index]
            }
            realStorage.withUnsafeMutableBufferPointer { real in
                imaginaryStorage.withUnsafeMutableBufferPointer { imaginary in
                    bake.dsp.fft(real.baseAddress! + offset, imaginary.baseAddress! + offset, size, table.cosines, table.sines)
                }
            }
            #expect(Array(realStorage[offset..<(offset + size)]) == baseline.real, "offset \(offset)")
            #expect(Array(imaginaryStorage[offset..<(offset + size)]) == baseline.imaginary, "offset \(offset)")
        }
    }

    @Test func transformSpeedAgainstTheReference() {
        // 2,000 frames of 4,096 points is about 3 minutes of audio at hop 1,024; printed, not asserted tightly.
        let size = 4_096
        let frames = 2_000
        let table = twiddles(size)
        let sourceReal = signal(size, seed: 1).real
        let sourceImaginary = signal(size, seed: 2).real
        var real = sourceReal
        var imaginary = sourceImaginary
        // Each run starts from the same input (copying costs both sides the same), so values never grow to infinity.
        func time(_ run: () -> Void) -> Double {
            let start = ContinuousClock.now
            for _ in 0..<frames {
                real = sourceReal
                imaginary = sourceImaginary
                run()
            }
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        }
        let accelerated = time { bake.dsp.fft(&real, &imaginary, size, table.cosines, table.sines) }
        let reference = time { bake.dsp.fftReference(&real, &imaginary, size, table.cosines, table.sines) }
        print("FFT speed, \(frames) x \(size) points: Accelerate \(accelerated) s, reference \(reference) s, \(reference / accelerated)x")
        #expect(accelerated < reference)
    }
}
