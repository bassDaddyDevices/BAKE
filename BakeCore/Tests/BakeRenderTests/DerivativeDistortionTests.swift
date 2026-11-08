import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct DerivativeDistortionTests {
    struct Settings {
        var slopeDrive: Float = 36
        var curveDrive: Float = 0
        var edge: Float = 0
        var splay: Float = 0
        var output: Float = 0
        var mix: Float = 1
        var oversampling: Int32 = 1
        var modulation: [String: [Float]] = [:]
    }

    /// Everything at its linear setting: the output follows the input exactly.
    static let linear = Settings(slopeDrive: 0)

    /// Renders one channel in `chunk`-frame calls, with state, scratch and history sized from the kernel.
    private func distort(_ input: [Float], _ settings: Settings, chunk: Int? = nil) -> [Float] {
        let maxCount = chunk ?? input.count
        var controls = bake.dsp.DerivativeDistortionControls()
        controls.slopeDrive = signal(settings.slopeDrive, 0, 72)
        controls.curveDrive = signal(settings.curveDrive, 0, 48)
        controls.edge = signal(settings.edge, -1, 1)
        controls.splay = signal(settings.splay, -1, 1)
        controls.output = signal(settings.output, -24, 24)
        controls.mix = signal(settings.mix, 0, 1)
        controls.sampleRate = 48_000
        controls.oversampling = settings.oversampling

        // Modulation buffers live until the render is done.
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }
        for (id, values) in settings.modulation {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
            _ = buffer.initialize(from: values)
            buffers.append(buffer)
            let pointer = UnsafePointer(buffer.baseAddress)
            switch id {
            case "slopeDrive": controls.slopeDrive.modulation = pointer; controls.slopeDrive.modulationFrames = values.count
            case "curveDrive": controls.curveDrive.modulation = pointer; controls.curveDrive.modulationFrames = values.count
            case "edge": controls.edge.modulation = pointer; controls.edge.modulationFrames = values.count
            case "splay": controls.splay.modulation = pointer; controls.splay.modulationFrames = values.count
            case "output": controls.output.modulation = pointer; controls.output.modulationFrames = values.count
            case "mix": controls.mix.modulation = pointer; controls.mix.modulationFrames = values.count
            default: Issue.record("unknown control \(id)")
            }
        }

        var state = bake.dsp.DerivativeDistortionState()
        var scratch = [Float](repeating: 0, count: max(bake.dsp.derivativeDistortionScratchFloats(settings.oversampling, maxCount), 1))
        var history = [Float](repeating: 0, count: max(bake.dsp.derivativeDistortionHistoryFloats(settings.oversampling), 1))
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < input.count {
                    let count = min(maxCount, input.count - start)
                    bake.dsp.renderDerivativeDistortion(
                        &state, controls, source.baseAddress!, input.count,
                        destination.baseAddress! + start, start, count, &scratch, &history
                    )
                    start += count
                }
            }
        }
        return output
    }

    private let steady = 4_800

    /// Per-sample steps of the steady-state output: the largest rise and the largest fall.
    private func steps(_ output: [Float]) -> (rise: Float, fall: Float) {
        var rise: Float = 0
        var fall: Float = 0
        for n in (steady + 1)..<output.count {
            let step = output[n] - output[n - 1]
            rise = max(rise, step)
            fall = max(fall, -step)
        }
        return (rise, fall)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
    }

    /// RMS below about 60 Hz (four one-pole lowpasses), after the first half second.
    private func lows(_ samples: [Float]) -> Float {
        var poles = [Double](repeating: 0, count: 4)
        let k = exp(-2 * Double.pi * 60 / 48_000)
        var sum = 0.0
        for (index, sample) in samples.enumerated() {
            var value = Double(sample)
            for j in 0..<4 {
                poles[j] = k * poles[j] + (1 - k) * value
                value = poles[j]
            }
            if index >= 24_000 { sum += value * value }
        }
        return Float(sqrt(sum / Double(max(samples.count - 24_000, 1))))
    }

    /// Seeded white noise at ±`amplitude`.
    private func noise(frames: Int, amplitude: Float = 1) -> [Float] {
        var seed: UInt32 = 7
        return (0..<frames).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(seed >> 8) / Float(1 << 23) - 1)
        }
    }

    /// Two seconds of a drum loop: a falling kick every 0.5 s, a noise snare on the off-beat, hats on eighths.
    private func drums() -> [Float] {
        var seed: UInt32 = 3
        func random() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed >> 8) / Double(1 << 23) - 1
        }
        return (0..<96_000).map { (n: Int) -> Float in
            let t = Double(n % 24_000) / 48_000
            let sweep: Double = 40 * t + 15 * (1 - exp(-t * 30)) / 30
            let kick: Double = sin(2 * Double.pi * sweep) * exp(-t * 8) * 0.8
            let s = Double((n + 12_000) % 24_000) / 48_000
            let snare: Double = random() * exp(-s * 25) * 0.4
            let h = Double(n % 6_000) / 48_000
            let hat: Double = random() * exp(-h * 120) * 0.2
            return Float(kick + snare + hat)
        }
    }

    /// A 110 / 138.6 / 164.8 Hz saw chord, two seconds.
    private func sawChord() -> [Float] {
        let notes: [Double] = [110, 138.6, 164.8]
        return (0..<96_000).map { (n: Int) -> Float in
            var sum = 0.0
            for note in notes {
                sum += fmod(Double(n) * note / 48_000, 1) - 0.5
            }
            return Float(sum * 0.25)
        }
    }

    /// Hann-windowed Goertzel power.
    private func power(of signal: ArraySlice<Float>, at frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / 48_000
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

    @Test func linearSettingsAreTheIdentity() {
        // Closed loop: with no shaping, every step lands on the input.
        let input = sine(frequency: 220, frames: 9_600).map { $0 + 0.2 }
        let output = distort(input, Self.linear)
        #expect(zip(output, input).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func fastMovementIsSlopeLimited() {
        // 24 dB: limiting starts at a full-scale 1250 Hz sine.
        let output = distort(sine(frequency: 5_000, frames: 9_600, amplitude: 1), Settings(slopeDrive: 24))
        let limit = Float(2 * Double.pi * 1_250 / 48_000)
        let (rise, fall) = steps(output)
        #expect(max(rise, fall) <= 1.01 * limit)
        #expect(min(rise, fall) >= 0.9 * limit)
    }

    @Test func slowMovementPasses() {
        let input = sine(frequency: 100, frames: 9_600, amplitude: 1)
        let driven = distort(input, Settings(slopeDrive: 24))
        #expect((steady..<input.count).allSatisfy { abs(driven[$0] - input[$0]) < 0.01 })
    }

    @Test func heavyDriveTurnsASawTowardsATriangle() {
        // 66 dB: onset ~10 Hz, so a 110 Hz saw's reset becomes a ramp of about half the period.
        let saw = (0..<9_600).map { Float($0 % 436) / 436 - 0.5 }
        let output = distort(saw, Settings(slopeDrive: 66))
        let (rise, fall) = steps(output)
        #expect(fall < 0.05)
        #expect(rise > 0.5 * fall)
    }

    @Test(arguments: ["drums", "saw chord"])
    func noSubBass(material: String) {
        // Regression: the first, open-loop design put out up to 50× the drums' sub energy (peaks of 26).
        let input = material == "drums" ? drums() : sawChord()
        let inputLows = lows(input)
        let inputPeak = input.map(abs).max() ?? 0
        var cases: [Settings] = []
        for drive: Float in [0, 12, 24, 36, 48, 60, 72] {
            cases.append(Settings(slopeDrive: drive, oversampling: 4))
        }
        for drive: Float in [12, 24, 36, 48] {
            cases.append(Settings(slopeDrive: 24, curveDrive: drive, oversampling: 4))
        }
        cases.append(Settings(splay: 1, oversampling: 4))
        cases.append(Settings(splay: -1, oversampling: 4))
        for settings in cases {
            let output = distort(input, settings)
            let label = "slope \(settings.slopeDrive) curve \(settings.curveDrive) splay \(settings.splay)"
            #expect(lows(output) <= 1.5 * inputLows + 0.01, "\(label)")
            #expect((output.map(abs).max() ?? 0) <= 1.5 * inputPeak, "\(label)")
        }
    }

    @Test func responseIsGradual() {
        // No 6 dB step of Slope Drive changes the saw chord's level by more than 6 dB.
        let input = sawChord()
        var previous = rms(input[24_000...])
        for drive in stride(from: Float(6), through: 72, by: 6) {
            let level = rms(distort(input, Settings(slopeDrive: drive, oversampling: 4))[24_000...])
            #expect(abs(decibels(level / previous)) < 6, "slope \(drive) dB")
            previous = level
        }
    }

    @Test func splayMakesEvenHarmonics() {
        // Different rising and falling limits make the waveform asymmetric: a 2 kHz sine gains 4 kHz.
        let input = sine(frequency: 2_000, frames: 9_600, amplitude: 1)
        let splayed = distort(input, Settings(slopeDrive: 24, splay: 0.5))[steady...]
        let even = distort(input, Settings(slopeDrive: 24))[steady...]
        #expect(power(of: splayed, at: 4_000) > 100 * power(of: even, at: 4_000))
    }

    @Test func asymmetricLimitingMakesNoDC() {
        let saw = (0..<48_000).map { Float($0 % 480) / 480 - 0.5 }
        let sine = sine(frequency: 2_000, frames: 48_000, amplitude: 1)
        for (input, settings) in [(saw, Settings()), (sine, Settings(splay: 0.5)), (sine, Settings(splay: -1, oversampling: 4))] {
            let tail = distort(input, settings)[24_000...]
            let mean = tail.reduce(0, +) / Float(tail.count)
            #expect(abs(mean) < 0.01)
            #expect(tail.allSatisfy { abs($0) < 2 })
        }
    }

    @Test func curveDriveRoundsCorners() {
        let square = (0..<9_600).map { Float(($0 / 120) % 2 == 0 ? 0.5 : -0.5) }
        let rounded = distort(square, Settings(slopeDrive: 0, curveDrive: 36))
        #expect(zip(rounded, square).contains { abs($0 - $1) > 0.05 })

        let low = sine(frequency: 100, frames: 9_600)
        let curved = distort(low, Settings(slopeDrive: 0, curveDrive: 36))
        #expect((steady..<low.count).allSatisfy { abs(curved[$0] - low[$0]) < 0.005 })
    }

    @Test func edgeTiltsTheHighs() {
        let input = zip(sine(frequency: 10_000, frames: 9_600, amplitude: 0.2), sine(frequency: 200, frames: 9_600)).map { $0 + $1 }
        func highs(_ edge: Float) -> Double {
            power(of: distort(input, Settings(slopeDrive: 0, edge: edge))[steady...], at: 10_000)
        }
        #expect(highs(1) > highs(0))
        #expect(highs(0) > highs(-1))
    }

    @Test func driveIsTheSameAtEveryOversampling() {
        let input = sine(frequency: 1_000, frames: 9_600)
        let reference = rms(distort(input, Settings(slopeDrive: 48))[steady...])
        for factor: Int32 in [2, 8, 32] {
            let level = rms(distort(input, Settings(slopeDrive: 48, oversampling: factor))[steady...])
            #expect(abs(decibels(level / reference)) < 1, "factor \(factor)")
        }
    }

    @Test func oversamplingAddsNoLatency() {
        let input = sine(frequency: 1_000, frames: 9_600)
        let base = distort(input, Self.linear)
        var high = Self.linear
        high.oversampling = 8
        let oversampled = distort(input, high)
        // A whole base frame of lag would misalign by ~0.065; the filter's passband ripple leaves ~0.001.
        // Away from the file's end, where the filter reads past the input.
        func error(lag: Int) -> Float {
            (steady..<9_000).map { abs(base[$0] - oversampled[$0 + lag]) }.max() ?? 0
        }
        #expect(error(lag: 0) < 2e-3)
        for lag in [-2, -1, 1, 2] {
            #expect(error(lag: 0) < error(lag: lag))
        }
    }

    @Test(arguments: [Int32(1), 2, 8, 32])
    func chunksOf777MatchOneRender(factor: Int32) {
        let input = noise(frames: 6_000, amplitude: 0.7)
        let settings = Settings(slopeDrive: 42, curveDrive: 30, edge: 0.5, splay: 0.3, oversampling: factor)
        #expect(distort(input, settings, chunk: 777) == distort(input, settings))
    }

    @Test func rendersAreBitIdentical() {
        let input = noise(frames: 6_000)
        let settings = Settings(curveDrive: 30, edge: -0.4, splay: -0.2, oversampling: 4)
        #expect(distort(input, settings) == distort(input, settings))
    }

    @Test(arguments: [Int32(1), 32])
    func extremesAreFinite(factor: Int32) {
        let input = noise(frames: 4_800)
        var cases: [Settings] = []
        for slope: Float in [0, 72] {
            for curve: Float in [0, 48] {
                for edge: Float in [-1, 1] {
                    for splay: Float in [-1, 1] {
                        cases.append(Settings(slopeDrive: slope, curveDrive: curve, edge: edge, splay: splay, oversampling: factor))
                    }
                }
            }
        }
        for output: Float in [-24, 24] { cases.append(Settings(output: output, oversampling: factor)) }
        for mix: Float in [0, 1] { cases.append(Settings(mix: mix, oversampling: factor)) }
        for settings in cases {
            let output = distort(input, settings)
            #expect(output.allSatisfy { $0.isFinite })
        }
    }

    @Test func mixAndOutput() {
        let input = noise(frames: 4_800, amplitude: 0.5)
        #expect(distort(input, Settings(mix: 0)) == input)
        let unity = distort(input, Settings())
        let louder = distort(input, Settings(output: 6))
        let gain = Float(pow(10, 6.0 / 20))
        #expect(zip(louder, unity).allSatisfy { abs($0 - gain * $1) <= 1e-4 * max(abs($0), 1e-3) })
    }

    @Test(arguments: ["slopeDrive", "curveDrive", "edge", "splay", "output", "mix"])
    func modulationMovesEveryControl(id: String) {
        let input = noise(frames: 4_800, amplitude: 0.7)
        let base = Settings(slopeDrive: 30, curveDrive: 30, mix: 0.5)
        var moved = base
        moved.modulation[id] = [Float](repeating: 0.3, count: input.count)
        let still = distort(input, base, chunk: 777)
        let modulated = distort(input, moved, chunk: 777)
        #expect(modulated != still)
        #expect(modulated == distort(input, moved))
    }

    /// Audio → Derivative Distortion (defaults) → Bake, in `chunk`-frame render chunks.
    private func renderChain(_ samples: [[Float]], chunk: Int) async throws -> [[Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let node = graph.add(.derivativeDistortion, NodeCatalog.defaultParameters(for: .derivativeDistortion))
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    @Test func audioDerivativeDistortionPrintKeepsLengthAndChannels() async throws {
        let samples = TestAudio.samples(frames: 48_000, channels: 2)
        let rendered = try await renderChain(samples, chunk: 4_096)
        #expect(rendered.count == 2)
        #expect(rendered.allSatisfy { $0.count == 48_000 })
        #expect(rendered.allSatisfy { $0.allSatisfy { $0.isFinite } })
        #expect(rendered[0] != samples[0])
        #expect(try await renderChain(samples, chunk: 777) == rendered)
    }
}
