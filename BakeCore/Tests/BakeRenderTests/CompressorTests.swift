import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct CompressorTests {
    private static let rate = 48_000.0

    private func signal(_ value: Float, minimum: Float = -1_000_000, maximum: Float = 1_000_000) -> bake.dsp.ParameterSignal {
        var signal = bake.dsp.ParameterSignal()
        signal.base = value
        signal.minimum = minimum
        signal.maximum = maximum
        return signal
    }

    /// 0.05 amplitude, then 0.8 from 0.5 s to 1 s, then 0.05 again: two seconds of a 440 Hz sine.
    private func burst() -> [Float] {
        let count = Int(Self.rate * 2)
        return (0..<count).map { index in
            let level: Float = (index > Int(Self.rate * 0.5) && index < Int(Self.rate)) ? 0.8 : 0.05
            return level * Float(sin(2 * Double.pi * 440 * Double(index) / Self.rate))
        }
    }

    private func gain(_ input: [Float], _ settings: bake.dsp.DynamicsSettings, rms: Bool = true) -> [Float] {
        let count = input.count
        var levels = [Float](repeating: 0, count: count)
        var curve = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = count
            audio.channels.0 = buffer.baseAddress
            bake.dsp.dynamicsLevels(audio, 0, rms, 10, Self.rate, count, &levels)
        }
        bake.dsp.dynamicsGainCurve(levels, count, settings, &curve)
        return curve
    }

    private func settings(threshold: Float = -20, ratio: Float = 4) -> bake.dsp.DynamicsSettings {
        var settings = bake.dsp.DynamicsSettings()
        settings.sampleRate = Self.rate
        settings.threshold = signal(threshold)
        settings.ratio = signal(ratio)
        settings.kneeDb = 0
        settings.attackMs = 10
        settings.releaseMs = 100
        return settings
    }

    @Test func compressesOnlyWhatIsOverTheThreshold() {
        let curve = gain(burst(), settings())
        // 0.8 amplitude is about -4.9 dB RMS: 15 dB over at 4:1 is 11.3 dB of reduction.
        #expect(abs(curve[Int(Self.rate * 0.8)] - -11.3) < 0.3)
        #expect(abs(curve[Int(Self.rate * 0.2)]) < 0.01)
    }

    @Test func theGainStartsFallingBeforeTheLoudPart() {
        let curve = gain(burst(), settings())
        let onset = Int(Self.rate * 0.5)
        #expect(curve[onset - Int(Self.rate * 0.005)] < -0.5)
    }

    @Test func releaseSettlesToTenPercentInTheReleaseTime() {
        let curve = gain(burst(), settings())
        let end = Int(Self.rate)
        var index = end
        while index < curve.count, curve[index] < -1.13 { index += 1 }
        let milliseconds = Double(index - end) * 1000 / Self.rate
        #expect(abs(milliseconds - 100) < 10, "settled after \(milliseconds) ms")
    }

    @Test func aGateClosesTheQuietPartAndLeavesTheLoudPartOpen() {
        var gate = settings(threshold: -20)
        gate.mode = .gate
        gate.rangeDb = 60
        gate.attackMs = 5
        gate.releaseMs = 50
        let curve = gate.mode == .gate ? gain(burst(), gate) : []
        #expect(abs(curve[Int(Self.rate * 0.2)] - -60) < 0.5)
        #expect(abs(curve[Int(Self.rate * 0.8)]) < 0.1)
    }

    @Test func autoMakeupMatchesTheInputLoudness() {
        let input = burst()
        var compressor = settings()
        compressor.attackMs = 0
        let curve = gain(input, compressor)
        let count = input.count
        var matched = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = count
            audio.channels.0 = buffer.baseAddress
            var pointer: UnsafePointer<Float>? = nil
            let before = curve.withUnsafeBufferPointer { curveBuffer -> (Double, Double) in
                pointer = curveBuffer.baseAddress
                let dry = bake.dsp.dynamicsLoudness(audio, nil, 0, Self.rate)
                let wet = withUnsafePointer(to: &pointer) { bake.dsp.dynamicsLoudness(audio, $0, 1, Self.rate) }
                return (dry, wet)
            }
            #expect(before.0 - before.1 > 5)
            let extra = before.0 - before.1
            curve.withUnsafeBufferPointer { curveBuffer in
                var curvePointer: UnsafePointer<Float>? = curveBuffer.baseAddress
                matched.withUnsafeMutableBufferPointer { out in
                    var outPointer: UnsafeMutablePointer<Float>? = out.baseAddress
                    bake.dsp.dynamicsRender(audio, &curvePointer, 1, signal(0), extra, signal(1), &outPointer, 1, 0, count)
                }
            }
        }
        matched.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = count
            audio.channels.0 = buffer.baseAddress
            let loudness = bake.dsp.dynamicsLoudness(audio, nil, 0, Self.rate)
            var reference = bake.dsp.AudioInput()
            input.withUnsafeBufferPointer { original in
                reference.channelCount = 1
                reference.frames = count
                reference.channels.0 = original.baseAddress
                let target = bake.dsp.dynamicsLoudness(reference, nil, 0, Self.rate)
                #expect(abs(loudness - target) < 0.1)
            }
        }
    }

    @Test func theCatalogPutsItInTheEffectsGroupWithASidechainPin() {
        let definition = NodeCatalog.definition(for: .compressor)
        #expect(NodeKind.compressor.category == .effects)
        #expect(definition.pins.contains { $0.id == "sidechain" && !$0.isRequired })
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(!NodeCatalog.isCausal(Node(kind: .compressor, parameters: [:])))
    }

    // MARK: Sidechain filters

    /// Reduction curve with the detector run through the sidechain filters.
    private func filteredGain(_ input: [Float], highPass: Double = 0, lowPass: Double = 0) -> [Float] {
        let count = input.count
        var levels = [Float](repeating: 0, count: count)
        var scratch = [Float](repeating: 0, count: count)
        var curve = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { buffer in
            var audio = bake.dsp.AudioInput()
            audio.channelCount = 1
            audio.frames = count
            audio.channels.0 = buffer.baseAddress
            bake.dsp.dynamicsLevelsFiltered(audio, 0, highPass, lowPass, true, 10, Self.rate, count, &levels, &scratch)
        }
        bake.dsp.dynamicsGainCurve(levels, count, settings(), &curve)
        return curve
    }

    private func tone(_ hertz: Double, amplitude: Float = 0.8) -> [Float] {
        (0..<Int(Self.rate)).map { amplitude * Float(sin(2 * Double.pi * hertz * Double($0) / Self.rate)) }
    }

    @Test func aHighPassKeepsBassOutOfTheDetector() {
        let bass = tone(80)
        let plain = filteredGain(bass)
        let filtered = filteredGain(bass, highPass: 1_000)
        let middle = Int(Self.rate * 0.5)
        #expect(plain[middle] < -5)
        #expect(abs(filtered[middle]) < 0.01)
    }

    @Test func aHighPassStillLetsTheTreble() {
        let treble = tone(5_000)
        let plain = filteredGain(treble)
        let filtered = filteredGain(treble, highPass: 1_000)
        let middle = Int(Self.rate * 0.5)
        #expect(abs(plain[middle] - filtered[middle]) < 0.3)
    }

    @Test func aLowPassKeepsTrebleOutOfTheDetector() {
        let treble = tone(6_000)
        let filtered = filteredGain(treble, lowPass: 500)
        let middle = Int(Self.rate * 0.5)
        #expect(abs(filtered[middle]) < 0.01)
        let bass = filteredGain(tone(80), lowPass: 500)
        #expect(bass[middle] < -5)
    }

    @Test func theNewSettingsDefaultToTheOldBehaviour() {
        let definition = NodeCatalog.definition(for: .compressor)
        func defaultNumber(_ id: String) -> Double? {
            guard let parameter = definition.parameters.first(where: { $0.id == id }),
                  case .number(_, let value, _) = parameter.kind else { return nil }
            return value
        }
        func defaultChoice(_ id: String) -> String? {
            guard let parameter = definition.parameters.first(where: { $0.id == id }),
                  case .choice(_, let value) = parameter.kind else { return nil }
            return value
        }
        let highPass = defaultNumber("scHighPass")
        let lowPass = defaultNumber("scLowPass")
        let mode = defaultChoice("stereoMode")
        #expect(highPass == 0)
        #expect(lowPass == 0)
        #expect(mode == "leftRight")
    }
}
