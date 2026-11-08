import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct SingleCycleTests {
    private func render(shape: bake.dsp.SingleCycleShape, frameSize: Int = 2_048, cycles: Int = 1,
                        phase: Float = 0, warp: Float = 0, morph: Float = 0, width: Float = 0.5,
                        partials: [Float] = [1, 0.5, 0.333, 0.25], seed: UInt64 = 1,
                        shapeModulation: [Float]? = nil, chunk: Int? = nil) -> [Float] {
        let shapeSignal = signal(Float(shape.rawValue), 0, 6)
        let widthSignal = signal(width, 0.01, 0.99)
        let phaseSignal = signal(phase, 0, 360)
        let warpSignal = signal(warp, -1, 1)
        let morphSignal = signal(morph, 0, 1)
        var output = [Float](repeating: 0, count: frameSize * cycles)
        let outputCount = output.count
        let paddedPartials = partials + Array(repeating: 0, count: max(0, 64 - partials.count))
        let modulation = shapeModulation ?? []
        var mutableShapeSignal = shapeSignal
        output.withUnsafeMutableBufferPointer { destination in
            paddedPartials.withUnsafeBufferPointer { partialPointer in
                modulation.withUnsafeBufferPointer { modulationPointer in
                    if !modulation.isEmpty {
                        mutableShapeSignal.modulation = modulationPointer.baseAddress
                        mutableShapeSignal.modulationFrames = modulationPointer.count
                    }
                    var start = 0
                    while start < outputCount {
                        let chunkCount = min(chunk ?? outputCount, outputCount - start)
                        bake.dsp.renderSingleCycle(
                            shape, mutableShapeSignal, widthSignal, phaseSignal, warpSignal, morphSignal,
                            partialPointer.baseAddress, partialPointer.count, seed,
                            destination.baseAddress! + start, frameSize, start, chunkCount
                        )
                        start += chunkCount
                    }
                }
            }
        }
        return output
    }

    @Test func sineMatchesItsExactKnownAnswer() {
        let output = render(shape: .sine)
        for index in output.indices {
            let expected = Float(sin(2 * Double.pi * Double(index) / 2_048))
            #expect(abs(output[index] - expected) < 1e-6)
        }
    }

    @Test func sawAndPulseHaveTheirDocumentedEndpoints() {
        let saw = render(shape: .saw)
        #expect(saw.first == -1)
        #expect(saw.last! < 1 && saw.last! > 0.99)
        let pulse = render(shape: .pulse)
        #expect(pulse[0] == 1 && pulse[1_023] == 1 && pulse[1_024] == -1)
    }

    @Test func shapeAndPhaseModulationAreSampledAtCycleStarts() {
        let values: [Float] = [0, Float(1.0 / 6), Float(2.0 / 6), Float(3.0 / 6)]
        let shapeCycle = values.flatMap { Array(repeating: $0, count: 2_048) }
        let output = render(shape: .sine, cycles: 4, shapeModulation: shapeCycle, chunk: 777)
        let cycles = (0..<4).map { Array(output[($0 * 2_048)..<(($0 + 1) * 2_048)]) }
        for first in cycles.indices {
            for second in cycles.indices where second > first {
                #expect(cycles[first] != cycles[second])
            }
        }
        for cycle in cycles {
            #expect(cycle.allSatisfy { $0.isFinite })
        }
    }

    @Test func additivePartialsKeepOnlyTheRequestedHarmonics() {
        let frameSize = 2_048
        let output = render(shape: .additive, frameSize: frameSize, partials: [1, 0, 0.333])
        func amplitude(_ harmonic: Int) -> Double {
            let frequency = Double(harmonic)
            let real = output.enumerated().reduce(0.0) { $0 + Double($1.element) * cos(2 * Double.pi * frequency * Double($1.offset) / Double(frameSize)) }
            let imaginary = output.enumerated().reduce(0.0) { $0 - Double($1.element) * sin(2 * Double.pi * frequency * Double($1.offset) / Double(frameSize)) }
            return hypot(real, imaginary) * 2 / Double(frameSize)
        }
        #expect(abs(amplitude(1) - 1 / 1.333) < 1e-3)
        #expect(abs(amplitude(3) - 0.333 / 1.333) < 1e-3)
        #expect(amplitude(2) < 1e-5)
    }

    @Test func parsesAtMost64PartialsAndTreatsInvalidTokensAsZero() {
        let parsed = SingleCycleProcessor.parsePartials("1 nope 0.25")
        #expect(parsed.count == 64)
        #expect(parsed[0] == 1 && parsed[1] == 0 && parsed[2] == 0.25)
        #expect(parsed.dropFirst(3).allSatisfy { $0 == 0 })
        #expect(SingleCycleProcessor.parsePartials((0..<70).map(String.init).joined(separator: " ")).count == 64)
    }

    private func modulatedRender(_ parameter: String, values: [Float], shape: bake.dsp.SingleCycleShape = .saw,
                                 widthValue: Float = 0.5, phaseValue: Float = 0, warpValue: Float = 0, morphValue: Float = 0) -> [Float] {
        let frameSize = 256, cycles = 4
        let shapeSignal = signal(Float(shape.rawValue), 0, 6)
        var width = signal(widthValue, 0.01, 0.99)
        var phase = signal(phaseValue, 0, 360)
        var warp = signal(warpValue, -1, 1)
        var morph = signal(morphValue, 0, 1)
        return values.withUnsafeBufferPointer { pointer in
            let source = UnsafePointer(pointer.baseAddress)
            switch parameter {
            case "width": width.modulation = source; width.modulationFrames = pointer.count
            case "phase": phase.modulation = source; phase.modulationFrames = pointer.count
            case "warp": warp.modulation = source; warp.modulationFrames = pointer.count
            case "morph": morph.modulation = source; morph.modulationFrames = pointer.count
            default: break
            }
            var output = [Float](repeating: 0, count: frameSize * cycles)
            output.withUnsafeMutableBufferPointer { destination in
                bake.dsp.renderSingleCycle(shape, shapeSignal, width, phase, warp, morph, nil, 0, 1,
                                           destination.baseAddress!, frameSize, 0, destination.count)
            }
            return output
        }
    }

    @Test func everyModulatableParameterChangesTheCycle() {
        let baseline = modulatedRender("width", values: [0.5, 0.5, 0.5, 0.5], shape: .pulse)
        #expect(modulatedRender("width", values: [0.2, 0.2, 0.2, 0.2], shape: .pulse) != baseline)
        #expect(modulatedRender("phase", values: [0, 0.25, 0.5, 0.75]) != baseline)
        #expect(modulatedRender("warp", values: [0, 0.4, 0.8, 1], shape: .triangle) != modulatedRender("warp", values: [0, 0, 0, 0], shape: .triangle))
        #expect(modulatedRender("morph", values: [0, 0.33, 0.66, 1]) != baseline)
        let shapeSignal = signal(Float(bake.dsp.SingleCycleShape.saw.rawValue), 0, 6)
        var changedShapeSignal = shapeSignal
        let shapeValues: [Float] = [0, 1.0 / 6, 2.0 / 6, 3.0 / 6]
        var changedShape = [Float](repeating: 0, count: 256 * shapeValues.count)
        let changedShapeCount = changedShape.count
        shapeValues.withUnsafeBufferPointer { pointer in
            changedShapeSignal.modulation = UnsafePointer(pointer.baseAddress)
            changedShapeSignal.modulationFrames = pointer.count
            changedShape.withUnsafeMutableBufferPointer { destination in
                bake.dsp.renderSingleCycle(.saw, changedShapeSignal, signal(0.5, 0.01, 0.99), signal(0, 0, 360), signal(0, -1, 1), signal(0, 0, 1), nil, 0, 1, destination.baseAddress!, 256, 0, changedShapeCount)
            }
        }
        #expect(changedShape != render(shape: .saw, frameSize: 256, cycles: 4))
    }

    @Test func rendersAreChunkInvariantDeterministicAndFiniteAtExtremes() {
        let whole = render(shape: .noise, frameSize: 512, cycles: 7, seed: 12_345)
        #expect(render(shape: .noise, frameSize: 512, cycles: 7, seed: 12_345, chunk: 777) == whole)
        #expect(render(shape: .noise, frameSize: 512, cycles: 7, seed: 12_345) == whole)
        #expect(render(shape: .noise, frameSize: 512, cycles: 7, seed: 12_346) != whole)
        for shape in [bake.dsp.SingleCycleShape.sine, .triangle, .saw, .square, .pulse, .noise, .additive] {
            let output = render(shape: shape, frameSize: 256, cycles: 3, phase: 360, warp: 1, morph: 1)
            #expect(output.allSatisfy { $0.isFinite })
        }
    }

    @Test func audioFreeSingleCycleFiltersBakeUsesGeneratedShape() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var graph = TestProject()
        let cycle = graph.add(.singleCycle, ["frameSize": .choice("256"), "cycles": .number(4)])
        let filters = graph.add(.filters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(cycle, to: filters)
        graph.connect(filters, to: print)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: [:]), assetURLs: [:], outputDirectory: output)
        let url = try #require(try await RenderEngine.render(request).outputs[print])
        let samples = try TestAudio.read(url).samples
        #expect(samples.count == 1 && samples[0].count == 1_024)
        #expect(samples[0].allSatisfy { $0.isFinite })
        #expect(samples[0].contains { abs($0) > 0.5 })
    }

    @Test func catalogUsesGeneratedMonoLengthAndFixedParameters() throws {
        let definition = NodeCatalog.definition(for: .singleCycle)
        #expect(definition.pins == [PinDefinition(id: "out", direction: .output, signal: .audio, isRequired: false, channels: .mono)])
        #expect(definition.lengthRule == .byChoice("mode", rules: ["oscillator": .seconds("length")], otherwise: .generated(frameSize: "frameSize", count: "cycles")))
        for id in ["mode", "frameSize", "cycles", "length", "seed", "partials"] {
            #expect(try #require(definition.parameter(id)).isModulatable == false)
        }
        #expect(try #require(definition.parameter("shape")).isModulatable)
        #expect(try #require(definition.parameter("width")).shownWhen == ParameterCondition("shape", in: ["pulse"]))
    }
}
