import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct QuantizerTests {
    private typealias Scale = bake.dsp.QuantizerScale
    private let scales: [Scale] = [.chromatic, .major, .minor, .pentatonic]

    /// `input` nil = unwired. `chunk` renders in pieces to check chunk invariance.
    private func render(_ scale: Scale, root: Int32 = 0, glide: Double = 0, _ input: [Float]? = nil, frames: Int? = nil, chunk: Int? = nil) -> [Float] {
        let count = frames ?? input?.count ?? 0
        var output = [Float](repeating: 0, count: count)
        let values = input ?? []
        var state = bake.dsp.QuantizerState()
        values.withUnsafeBufferPointer { pointer in
            output.withUnsafeMutableBufferPointer { destination in
                var control = bake.dsp.ControlInput()
                if input != nil { control.samples = pointer.baseAddress; control.frames = pointer.count }
                var start = 0
                while start < count {
                    let size = min(chunk ?? count, count - start)
                    bake.dsp.renderQuantizer(&state, scale, root, glide, control, destination.baseAddress! + start, start, size)
                    start += size
                }
            }
        }
        return output
    }

    /// Semitones → control value (±24 st = ±1).
    private func control(_ semitones: [Float]) -> [Float] { semitones.map { $0 / 24 } }

    /// Control value → semitones, rounded to the note.
    private func notes(_ output: [Float]) -> [Int] { output.map { Int(($0 * 24).rounded()) } }

    // Inputs below are chosen away from ties (exactly halfway between two notes goes down).

    @Test func chromaticSnapsToTheNearestSemitone() {
        #expect(notes(render(.chromatic, control([0, 0.3, 0.7, 3.4, -2.6]))) == [0, 0, 1, 3, -3])
    }

    @Test func majorMinorAndPentatonicSnapToTheirNotes() {
        #expect(notes(render(.major, control([0, 1.4, 3.2, 5.9, -1.4]))) == [0, 2, 4, 5, -1])
        #expect(notes(render(.minor, control([4.2, 3.9, 8.1, 11.2]))) == [5, 3, 8, 12])
        #expect(notes(render(.pentatonic, control([5.1, 5.9, 1.2, 10.2]))) == [4, 7, 2, 9])
    }

    @Test func theRootMovesTheScale() {
        // D major has F♯ (6) but not F (5); C major the other way round.
        #expect(notes(render(.major, root: 2, control([6.2, 5.2]))) == [6, 6])
        #expect(notes(render(.major, root: 0, control([5.2]))) == [5])
    }

    @Test func rootsWrapAroundTheOctave() {
        let input = control([3.2, -7.7, 14.1])
        #expect(render(.major, root: 12, input) == render(.major, root: 0, input))
        #expect(render(.major, root: -1, input) == render(.major, root: 11, input))
    }

    @Test func everyResultIsInTheScaleInRangeAndTheNearestNote() {
        let degrees = [Array(0..<12), [0, 2, 4, 5, 7, 9, 11], [0, 2, 3, 5, 7, 8, 10], [0, 2, 4, 7, 9]]   // in `scales` order
        let input = (0...600).map { Float($0) / 200 - 1.5 }     // −1.5 … 1.5
        for (scale, degrees) in zip(scales, degrees) {
            for root in 0..<12 {
                let allowed = (-24...24).filter { degrees.contains((($0 - root) % 12 + 12) % 12) }
                let output = render(scale, root: Int32(root), input)
                for (value, result) in zip(input, output) {
                    let semitones = min(max(value, -1), 1) * 24
                    let note = Int((result * 24).rounded())
                    #expect(abs(result * 24 - Float(note)) < 1e-4 && allowed.contains(note) && abs(result) <= 1)
                    #expect(abs(abs(semitones - Float(note)) - allowed.map { abs(semitones - Float($0)) }.min()!) < 1e-3)
                }
            }
        }
    }

    @Test func theEndsOfTheRangeStayWithinPlusMinusOne() {
        #expect(render(.chromatic, [1, -1, 5, -5]) == [1, -1, 1, -1])
        for scale in scales {
            for root in 0..<12 {
                #expect(render(scale, root: Int32(root), [1, -1, 0.99, -0.99]).allSatisfy { abs($0) <= 1 })
            }
        }
    }

    @Test func nonFiniteInputsStayFiniteAndBounded() {
        let wild: [Float] = [.nan, .infinity, -.infinity, 3.4e38, -3.4e38]
        for scale in scales {
            #expect(render(scale, root: 7, wild).allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
    }

    @Test func unwiredReadsZeroAndAShortSourceHoldsItsLastValue() {
        #expect(render(.chromatic, frames: 3) == [0, 0, 0])
        #expect(notes(render(.chromatic, control([7]), frames: 5)) == [7, 7, 7, 7, 7])
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let input = sine(frequency: 5, frames: 5_000, amplitude: 1)
        for scale in scales {
            #expect(render(scale, root: 3, input, chunk: 777) == render(scale, root: 3, input))
        }
    }

    @Test func glideSlidesToEachNewNoteWithTheGivenTimeConstant() {
        var step = [Float](repeating: 0, count: 2_000)
        for index in 1_000..<2_000 { step[index] = 0.5 }             // up an octave at frame 1000
        let glided = render(.chromatic, glide: 200, step)
        #expect(glided[0] == 0 && glided[999] == 0)                  // starts on the first note, no slide from nowhere
        #expect(abs(Double(glided[1_199]) - 0.5 * (1 - exp(-1.0))) < 0.01)   // 63% of the way after one time constant
        #expect(glided[1_001] > glided[1_000] && glided[1_500] > glided[1_001])
        #expect(glided[1_999] > 0.49 && glided[1_999] <= 0.5)
        #expect(render(.chromatic, glide: 0, step) == render(.chromatic, step))
    }

    @Test func glideCarriesAcrossChunks() {
        let input = sine(frequency: 5, frames: 5_000, amplitude: 1)
        #expect(render(.major, glide: 300, input, chunk: 777) == render(.major, glide: 300, input))
    }

    @Test func glideChangesTheEngineRender() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jump = try await chain(directory: directory)
        let slide = try await chain(glide: 0.05, directory: directory)
        #expect(jump != slide)
    }

    @Test func rendersAreBitIdentical() {
        let input = sine(frequency: 5, frames: 2_000, amplitude: 1)
        #expect(render(.minor, root: 9, input) == render(.minor, root: 9, input))
    }

    @Test func everyScaleAndRootChangesTheResult() {
        let input = (0..<5_000).map { Float(sin(Double($0) * 0.004)) }
        let results = scales.map { render($0, input) }
        for first in results.indices {
            for second in results.indices where second > first {
                #expect(results[first] != results[second], "\(scales[first]) vs \(scales[second])")
            }
        }
        #expect(render(.major, root: 0, input) != render(.major, root: 1, input))
    }

    // MARK: end to end

    private enum Source { case lfo, unwired, short }

    /// LFO → Quantizer → `mod.cutoff` of Filters on Audio → Filters → Print.
    private func chain(scale: String = "major", root: String = "0", source: Source = .lfo, glide: Double = 0, directory: URL, bypass: Bool = false) async throws -> [[Float]] {
        let audioFile = directory.appendingPathComponent("source.wav")
        try TestAudio.write([sine(frequency: 440, frames: 8_192)], to: audioFile, sampleRate: 48_000)
        let shortAsset = AssetID(testUUID(9_600))
        let shortFile = directory.appendingPathComponent("short.wav")
        try TestAudio.write([sine(frequency: 5, frames: 2_000, amplitude: 0.9)], to: shortFile, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let lfo = graph.add(.lfo, ["rate": .number(3)])
        let quantizer = graph.add(.quantizer, ["scale": .choice(scale), "root": .choice(root), "glide": .number(glide)])
        let filters = graph.add(.filters, ["cutoff": .number(700)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        let index = try #require(graph.project.nodes.firstIndex { $0.id == filters })
        graph.project.nodes[index].setModulated("cutoff", true)
        graph.connect(audio, to: filters)
        switch source {
        case .lfo: graph.connect(lfo, to: quantizer, "in")
        case .short: graph.connect(graph.add(.audio, asset: shortAsset), to: quantizer, "in")
        case .unwired: break
        }
        graph.connect(bypass ? lfo : quantizer, to: filters, "mod.cutoff")
        graph.connect(filters, to: print)
        let urls = [sourceAsset: audioFile, shortAsset: shortFile]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        return try TestAudio.read(written).samples
    }

    @Test func aQuantizedLFODrivesAFilterCutoff() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rendered = try await chain(directory: directory)
        let bypassed = try await chain(directory: directory, bypass: true)

        #expect(rendered.count == 1 && rendered[0].count == 8_192)
        #expect(rendered[0].allSatisfy { $0.isFinite })
        #expect(rendered != bypassed)
    }

    @Test func aShorterSourceOnInStaysFiniteAndFullLength() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rendered = try await chain(source: .short, directory: directory)

        #expect(rendered.count == 1 && rendered[0].count == 8_192)
        #expect(rendered[0].allSatisfy { $0.isFinite })
    }

    @Test func theScaleAndRootSettingsChangeTheRender() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let major = try await chain(scale: "major", directory: directory)
        let pentatonic = try await chain(scale: "pentatonic", directory: directory)
        let shifted = try await chain(scale: "major", root: "1", directory: directory)

        #expect(major != pentatonic)
        #expect(major != shifted)
    }

    @Test func pinsAndDefaultsAreAsDocumented() throws {
        let definition = NodeCatalog.definition(for: .quantizer)
        #expect(definition.pins.map(\.id) == ["in", "out"])
        #expect(definition.pins.allSatisfy { $0.signal == .control })
        #expect(definition.lengthRule == .followsConsumers)
        #expect(try #require(definition.parameter("scale")).defaultValue == .choice("chromatic"))
        #expect(try #require(definition.parameter("root")).defaultValue == .choice("0"))
        #expect(try #require(definition.parameter("glide")).defaultValue == .number(0))
    }
}
