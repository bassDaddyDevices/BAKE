import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Spectral Resynthesis kernel (BakeDSP/Resynthesis.h) and the node around it.
struct ResynthesisTests {
    private typealias Settings = bake.dsp.ResynthesisSettings
    private let sampleRate = 48_000.0
    private let frames = 144_000

    private func noise(_ count: Int, amplitude: Float, seed: UInt32) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(state >> 8) / 8_388_608 - 1)
        }
    }

    private func settings(
        fftSize: Int32 = 4_096, partials: Int32 = 128, hysteresis: Double = 0.3, parity: bake.dsp.PartialParity = .all
    ) -> Settings {
        var settings = Settings()
        settings.fftSize = fftSize
        settings.partials = partials
        settings.hysteresis = hysteresis
        settings.parity = parity
        return settings
    }

    private func resynthesise(
        _ settings: Settings, _ input: [Float], tilt: Float = 0, balance: Float = 0.5, chunk: Int? = nil, seed: UInt32 = 0
    ) -> [Float] {
        let count = input.count
        let maxCount = chunk ?? count
        var table = [Float](repeating: 0, count: Int(bake.dsp.resynthesisTableFloats(settings, count)))
        let scratchBytes = Int(bake.dsp.resynthesisScratchBytes(settings, maxCount))
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchBytes, alignment: 16)
        defer { scratch.deallocate() }
        var work = [Float](repeating: 0, count: max(
            Int(bake.dsp.resynthesisAnalysisWorkFloats(settings)), Int(bake.dsp.resynthesisRenderWorkFloats(settings, maxCount))
        ))
        var output = [Float](repeating: 0, count: count)
        let tiltSignal = signal(tilt, -12, 12)
        let balanceSignal = signal(balance, 0, 1)
        input.withUnsafeBufferPointer { source in
            bake.dsp.resynthesisAnalyse(settings, sampleRate, source.baseAddress!, count, &table, scratch, &work)
            output.withUnsafeMutableBufferPointer { destination in
                var start = 0
                while start < count {
                    let length = min(maxCount, count - start)
                    bake.dsp.resynthesisRender(
                        settings, sampleRate, tiltSignal, balanceSignal, source.baseAddress!, count, table,
                        destination.baseAddress! + start, start, length, seed, scratch, &work
                    )
                    start += length
                }
            }
        }
        return output
    }

    private func rms(_ signal: [Float], _ range: Range<Int>) -> Float {
        let sum = signal[range].reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float((sum / Double(range.count)).squareRoot())
    }

    /// Hann-windowed Goertzel amplitude of a sine at `frequency`.
    private func amplitude(_ signal: [Float], _ range: Range<Int>, at frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        var (real, imaginary) = (0.0, 0.0)
        for index in range {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(index - range.lowerBound) / Double(range.count))
            real += hann * Double(signal[index]) * cos(w * Double(index))
            imaginary += hann * Double(signal[index]) * sin(w * Double(index))
        }
        return (real * real + imaginary * imaginary).squareRoot() / (0.25 * Double(range.count))
    }

    private func harmonics(_ count: Int = 8) -> [Float] {
        (0..<frames).map { index in
            var sum = 0.0
            for h in 1...count { sum += 0.2 / Double(h) * sin(2 * Double.pi * 200 * Double(h) * Double(index) / sampleRate) }
            return Float(sum)
        }
    }

    @Test func aSineComesBackAsItself() {
        let input = sine(frequency: 440, frames: frames)
        let both = resynthesise(settings(), input)
        let sinesOnly = resynthesise(settings(), input, balance: 0)
        let middle = 20_000..<(frames - 20_000)
        #expect(middle.map { abs(both[$0] - input[$0]) }.max()! < 0.03)
        #expect(middle.map { abs(sinesOnly[$0] - input[$0]) }.max()! < 0.01)
        // Everything the partial doesn't explain is far quieter than the sine.
        #expect(rms(resynthesise(settings(), input, balance: 1), middle) < 0.02)
    }

    @Test func glidingAndVibratoPartialsKeepTheirLevel() {
        var phases = (0.0, 0.0, 0.0)
        let chord: [Float] = (0..<frames).map { index in
            let t = Double(index) / sampleRate
            phases.0 += 2 * Double.pi * (300 + 20 * sin(2 * Double.pi * 5 * t)) / sampleRate
            phases.1 += 2 * Double.pi * (300 + 100 * t) * 1.5 / sampleRate
            phases.2 += 2 * Double.pi * 1_234 / sampleRate
            return Float(0.3 * sin(phases.0) + 0.2 * sin(phases.1) + 0.1 * sin(phases.2))
        }
        let output = resynthesise(settings(), chord)
        let middle = 20_000..<(frames - 20_000)
        let ratio = rms(output, middle) / rms(chord, middle)
        #expect(ratio > 0.9 && ratio < 1.1)
    }

    @Test func anyChunkSizeGivesTheSameBits() {
        let input = noise(frames, amplitude: 0.3, seed: 4)
        let configured = settings(partials: 64, parity: .all)
        let whole = resynthesise(configured, input, tilt: 3, balance: 0.4, seed: 5)
        #expect(resynthesise(configured, input, tilt: 3, balance: 0.4, chunk: 777, seed: 5) == whole)
        #expect(resynthesise(configured, input, tilt: 3, balance: 0.4, chunk: 1_025, seed: 5) == whole)
    }

    @Test func theResidualKeepsTheLevelOfTheNoiseUnderATone() {
        let bed = noise(frames, amplitude: 0.05, seed: 12)
        let mix: [Float] = (0..<frames).map { index in
            var sum = 0.0
            for h in 1...6 { sum += 0.2 / Double(h) * sin(2 * Double.pi * 220 * Double(h) * Double(index) / sampleRate) }
            return Float(sum) + bed[index]
        }
        let middle = 20_000..<(frames - 20_000)
        let full = resynthesise(settings(), mix)
        #expect(abs(20 * log10(rms(full, middle) / rms(mix, middle))) < 1)
        let residual = resynthesise(settings(), mix, balance: 1)
        #expect(abs(20 * log10(rms(residual, middle) / rms(bed, middle))) < 3.5)
    }

    @Test func tiltTurnsHigherPartialsUpAndDown() {
        let two: [Float] = (0..<frames).map { index in
            Float(0.3 * sin(2 * Double.pi * 1_000 * Double(index) / sampleRate) + 0.3 * sin(2 * Double.pi * 2_000 * Double(index) / sampleRate))
        }
        let range = 40_000..<60_000
        let flat = resynthesise(settings(), two, balance: 0)
        let tilted = resynthesise(settings(), two, tilt: 6, balance: 0)
        let flatStep = 20 * log10(amplitude(flat, range, at: 2_000) / amplitude(flat, range, at: 1_000))
        let tiltedStep = 20 * log10(amplitude(tilted, range, at: 2_000) / amplitude(tilted, range, at: 1_000))
        #expect(abs(flatStep) < 0.3)
        #expect(abs(tiltedStep - 6) < 0.5)
    }

    @Test func oddAndEvenKeepOnlyThoseHarmonics() {
        let input = harmonics()
        let range = 40_000..<60_000
        func levels(_ parity: bake.dsp.PartialParity) -> [Double] {
            let output = resynthesise(settings(parity: parity), input, balance: 0)
            return (1...8).map { amplitude(output, range, at: 200 * Double($0)) }
        }
        let all = levels(.all)
        let odd = levels(.odd)
        let even = levels(.even)
        #expect(abs(all[0] - 0.2) < 0.01 && abs(all[3] - 0.05) < 0.005)
        #expect(odd[0] > 0.18 && odd[2] > 0.06 && odd[1] < 0.01 && odd[3] < 0.01)
        #expect(even[1] > 0.09 && even[3] > 0.045 && even[0] < 0.01 && even[2] < 0.01)
    }

    @Test func morePartialsCarryMoreOfARichSound() {
        let rich = noise(frames, amplitude: 0.3, seed: 9)
        let middle = 20_000..<(frames - 20_000)
        let few = rms(resynthesise(settings(partials: 16), rich, balance: 0), middle)
        let many = rms(resynthesise(settings(partials: 1_024), rich, balance: 0), middle)
        #expect(many > 3 * few)
    }

    @Test func everyFrameSizeKeepsASteadyToneAtItsLevel() {
        let two: [Float] = (0..<frames).map { index in
            Float(0.3 * sin(2 * Double.pi * 1_000 * Double(index) / sampleRate) + 0.3 * sin(2 * Double.pi * 2_000 * Double(index) / sampleRate))
        }
        for size: Int32 in [1_024, 2_048, 4_096, 8_192, 16_384] {
            let output = resynthesise(settings(fftSize: size), two)
            let ratio = rms(output, 30_000..<(frames - 30_000)) / rms(two, 30_000..<(frames - 30_000))
            #expect(ratio > 0.9 && ratio < 1.1, "\(size)")
        }
    }

    @Test func silenceStaysSilentAndExtremesStayFinite() {
        #expect(resynthesise(settings(), [Float](repeating: 0, count: frames)).allSatisfy { $0 == 0 })
        let rich = noise(frames, amplitude: 0.3, seed: 9)
        let extreme = resynthesise(settings(fftSize: 1_024, partials: 1_024, hysteresis: 1), rich, tilt: 12, chunk: 777)
        #expect(extreme.allSatisfy { $0.isFinite })
        let fewest = resynthesise(settings(fftSize: 16_384, partials: 16, hysteresis: 0), rich, tilt: -12, balance: 0.9, chunk: 777)
        #expect(fewest.allSatisfy { $0.isFinite })
    }

    @Test func differentChannelsGetDifferentNoise() {
        let input = noise(frames, amplitude: 0.3, seed: 4)
        #expect(resynthesise(settings(), input, balance: 1, seed: 0) != resynthesise(settings(), input, balance: 1, seed: 1))
    }
}

/// The Spectral Resynthesis node end to end.
struct ResynthesisNodeTests {
    private func makePatch(in directory: URL, channels: Int = 1, frames: Int = 60_000) throws -> (Patch, NodeID) {
        var patch = Patch()
        try patch.source(sourceAsset, channels: channels, frames: frames, in: directory)
        let source = patch.graph.add(.audio, asset: sourceAsset)
        let node = patch.graph.add(.spectralResynthesis)
        patch.wire(source, "out", to: node)
        return (patch, node)
    }

    @Test func rendersTheInputsLengthAndChannels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var (patch, node) = try makePatch(in: directory, channels: 2)
        patch.bake("rebuilt", from: node)

        let output = try #require(try await patch.render(in: directory)["rebuilt"])

        #expect(output.count == 2)
        #expect(output.allSatisfy { $0.count == 60_000 })
        #expect(output.allSatisfy { $0.allSatisfy { $0.isFinite } })
        #expect(output[0].contains { abs($0) > 0.01 })
    }

    @Test func chunkSizeDoesNotChangeTheBake() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var (patch, node) = try makePatch(in: directory)
        patch.bake("rebuilt", from: node)

        let small = try #require(try await patch.render(in: directory, chunkFrames: 777)["rebuilt"])
        let large = try #require(try await patch.render(in: directory, chunkFrames: 65_536)["rebuilt"])

        #expect(small == large)
    }

    @Test func theCatalogEntry() throws {
        let definition = NodeCatalog.definition(for: .spectralResynthesis)
        #expect(definition.pins.map(\.id) == ["in", "b", "freeze", "out"])
        #expect(definition.lengthRule == .scaledInput("in", by: "stretch"))
        let partials = try #require(definition.parameter("partials"))
        #expect(partials.role == .macro && partials.defaultValue == .number(128))
        #expect(try #require(definition.parameter("fftSize")).role == .setting)
        #expect(definition.parameter("tilt")?.isModulatable == true && definition.parameter("balance")?.isModulatable == true)
    }
}
