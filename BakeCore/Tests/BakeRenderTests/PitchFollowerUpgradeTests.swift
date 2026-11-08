import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Pitch Follower's upgrades: parallel analysis, the whole-file pitch path, zero-phase Glide and finer resolutions.
/// The defaults are pinned by `PitchFollowerGoldenTests`.
struct PitchFollowerUpgradeTests {
    private static let sampleRate = 48_000.0

    private struct Options {
        var smoothing = bake.dsp.PitchFollowerSmoothing.median
        var glidePhase = bake.dsp.PitchFollowerGlidePhase.causal
        var hop = 5.0
        var glide: Float = 15
        var output = bake.dsp.PitchFollowerOutput.log
        var minFreq: Float = 60
        var maxFreq: Float = 1_000
    }

    /// A sine whose frequency is `frequency(seconds)`.
    private func sine(_ frames: Int, _ frequency: (Double) -> Double) -> [Float] {
        var phase = 0.0
        return (0..<frames).map { index in
            phase += 2 * Double.pi * frequency(Double(index) / Self.sampleRate) / Self.sampleRate
            return Float(0.5 * sin(phase))
        }
    }

    /// Renders mono `samples`. `chunk` splits the render; `analysePieces` analyses each chunk's estimates in that many
    /// separate pieces, last piece first, each with its own scratch, as the processor does across cores.
    private func run(_ samples: [Float], _ options: Options = Options(), chunk: Int? = nil, analysePieces: Int = 0)
        -> (pitch: [Float], confidence: [Float]) {
        let frames = samples.count
        var controls = bake.dsp.PitchFollowerControls()
        controls.minFreq = signal(options.minFreq, 30, 2_000, scale: .exponential)
        controls.maxFreq = signal(options.maxFreq, 100, 4_000, scale: .exponential)
        controls.glide = signal(options.glide, 0, 500)
        controls.threshold = signal(0.6, 0, 1)
        controls.output = signal(Float(options.output.rawValue), 0, 2)
        controls.unvoiced = signal(0, 0, 2)
        controls.fixedOutput = options.output
        controls.sampleRate = Self.sampleRate
        controls.smoothing = options.smoothing
        controls.glidePhase = options.glidePhase
        controls.hopMilliseconds = options.hop
        var glideBuffer = [Float](repeating: 0, count: frames)

        let count = Int(bake.dsp.pitchFollowerEstimateCount(frames, Self.sampleRate, options.hop))
        var estimates = [Float](repeating: 0, count: max(count, 1) * Int(bake.dsp.pitchFollowerFloatsPerEstimate()))
        let scratchSize = Int(bake.dsp.pitchFollowerScratchDoubles(Self.sampleRate))
        var scratch = [Double](repeating: 0, count: scratchSize)
        var pieceScratch = (0..<max(analysePieces, 1)).map { _ -> [Double] in
            var buffer = [Double](repeating: 0, count: scratchSize)
            bake.dsp.pitchFollowerPrepareScratch(Self.sampleRate, &buffer)
            return buffer
        }
        var state = bake.dsp.PitchFollowerState()
        var pitch = [Float](repeating: 0, count: frames)
        var confidence = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { left in
            glideBuffer.withUnsafeMutableBufferPointer { glidePointer in
                controls.glideBuffer = options.glidePhase == .zeroPhase ? glidePointer.baseAddress : nil
                controls.glideFrames = options.glidePhase == .zeroPhase ? frames : 0
                var input = bake.dsp.AudioInput()
                input.channels.0 = left.baseAddress
                input.channelCount = 1
                input.frames = frames
                pitch.withUnsafeMutableBufferPointer { pitchPointer in
                    confidence.withUnsafeMutableBufferPointer { confidencePointer in
                        var start = 0
                        while start < frames {
                            let length = min(chunk ?? frames, frames - start)
                            if analysePieces > 0 {
                                let first = Int(state.analysed)
                                let last = min(Int(bake.dsp.pitchFollowerEstimatesNeeded(state, controls, count, start, length)), count)
                                if last > first {
                                    let pieces = min(analysePieces, last - first)
                                    let size = (last - first + pieces - 1) / pieces
                                    for piece in (0..<pieces).reversed() {
                                        let from = first + piece * size
                                        let to = min(from + size, last)
                                        if from < to {
                                            bake.dsp.pitchFollowerAnalyse(controls, input, &estimates, from, to, &pieceScratch[piece])
                                        }
                                    }
                                    state.analysed = last
                                }
                            }
                            bake.dsp.renderPitchFollower(
                                &state, controls, input, &estimates, count, &scratch,
                                pitchPointer.baseAddress! + start, confidencePointer.baseAddress! + start, start, length
                            )
                            start += length
                        }
                    }
                }
            }
        }
        return (pitch, confidence)
    }

    private func mean(_ values: ArraySlice<Float>) -> Double { values.reduce(0.0) { $0 + Double($1) } / Double(values.count) }

    @Test func analysingInPiecesChangesNothing() {
        let samples = sine(30_000) { _ in 150 }
        for smoothing in [bake.dsp.PitchFollowerSmoothing.median, .path] {
            var options = Options()
            options.smoothing = smoothing
            let serial = run(samples, options)
            for pieces in [2, 5] {
                let split = run(samples, options, analysePieces: pieces)
                #expect(split.pitch == serial.pitch && split.confidence == serial.confidence, "\(smoothing) \(pieces) pieces")
                let chunked = run(samples, options, chunk: 777, analysePieces: pieces)
                #expect(chunked.pitch == serial.pitch && chunked.confidence == serial.confidence, "\(smoothing) \(pieces) pieces, chunk 777")
            }
        }
    }

    @Test func everyModeGivesTheSameBitsInAnyChunking() {
        let samples = sine(30_000) { _ in 130 }
        var path = Options()
        path.smoothing = .path
        var zero = Options()
        zero.glidePhase = .zeroPhase
        zero.glide = 80
        var fine = Options()
        fine.hop = 1
        var all = Options()
        all.smoothing = .path
        all.glidePhase = .zeroPhase
        all.hop = 0.5
        for (name, options) in [("path", path), ("zero", zero), ("fine", fine), ("all", all)] {
            let whole = run(samples, options)
            let chunked = run(samples, options, chunk: 777)
            #expect(whole.pitch == chunked.pitch && whole.confidence == chunked.confidence, "\(name)")
            #expect(whole.pitch.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(name)")
        }
    }

    @Test func thePathTracksASteadyNote() {
        let samples = sine(30_000) { _ in 220 }
        var options = Options()
        options.smoothing = .path
        options.output = .note
        let result = run(samples, options)
        let expected = (69 + 12 * log2(220.0 / 440)) / 127
        #expect(abs(mean(result.pitch[12_000..<28_000]) - expected) < 0.5 / 127)
    }

    /// A rising glide trails a causal Glide by about its time constant; zero phase stays on the pitch.
    @Test func zeroPhaseGlideDoesNotLag() {
        let samples = sine(48_000) { seconds in 80 + 320 * seconds.clamped(to: 0...1) }
        var base = Options()
        base.glide = 0
        let target = run(samples, base)
        var causal = Options()
        causal.glide = 100
        var zero = causal
        zero.glidePhase = .zeroPhase
        let lagging = run(samples, causal)
        let aligned = run(samples, zero)
        let middle = 12_000..<30_000
        func offset(_ other: [Float]) -> Double {
            abs(mean(other[middle]) - mean(target.pitch[middle]))
        }
        #expect(offset(lagging.pitch) > 0.005, "causal Glide should trail the target")
        #expect(offset(aligned.pitch) < offset(lagging.pitch) * 0.4, "zero phase \(offset(aligned.pitch)) vs causal \(offset(lagging.pitch))")
    }

    @Test func finerResolutionMeansMoreEstimates() {
        let frames = 48_000
        let coarse = bake.dsp.pitchFollowerEstimateCount(frames, Self.sampleRate, 5)
        let fine = bake.dsp.pitchFollowerEstimateCount(frames, Self.sampleRate, 0.25)
        #expect(coarse == bake.dsp.pitchFollowerEstimateCount(frames, Self.sampleRate))
        #expect(fine > coarse * 15)
    }

    @Test func catalogOffersTheUpgradesOffByDefault() throws {
        let definition = NodeCatalog.definition(for: .pitchFollower)
        func options(_ id: String) throws -> [String] {
            let parameter = try #require(definition.parameters.first { $0.id == id })
            guard case .choice(let options, _) = parameter.kind else {
                Issue.record("\(id) should be a choice")
                return []
            }
            return options
        }
        #expect(try options("smoothing") == ["median", "path"])
        #expect(try options("glidePhase") == ["causal", "zeroPhase"])
        #expect(try options("resolution").first == "5")
        let defaults = NodeCatalog.defaultParameters(for: .pitchFollower)
        #expect(defaults["smoothing"] == .choice("median"))
        #expect(defaults["glidePhase"] == .choice("causal"))
        #expect(defaults["resolution"] == .choice("5"))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
