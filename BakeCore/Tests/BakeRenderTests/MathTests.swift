import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct MathTests {
    private typealias Operator = bake.dsp.MathOperator

    /// `a` and `b` nil = unwired. `chunk` renders in pieces to check chunk invariance.
    private func render(
        _ op: Operator, a: [Float]? = nil, b: [Float]? = nil, scale: Float = 1, minimum: Float = -16, maximum: Float = 16,
        frames: Int? = nil, chunk: Int? = nil
    ) -> [Float] {
        let count = frames ?? max(a?.count ?? 0, b?.count ?? 0)
        var output = [Float](repeating: 0, count: count)
        let aValues = a ?? [], bValues = b ?? []
        aValues.withUnsafeBufferPointer { aPointer in
            bValues.withUnsafeBufferPointer { bPointer in
                output.withUnsafeMutableBufferPointer { destination in
                    var inputA = bake.dsp.ControlInput(), inputB = bake.dsp.ControlInput()
                    if a != nil { inputA.samples = aPointer.baseAddress; inputA.frames = aPointer.count }
                    if b != nil { inputB.samples = bPointer.baseAddress; inputB.frames = bPointer.count }
                    var start = 0
                    while start < count {
                        let size = min(chunk ?? count, count - start)
                        bake.dsp.renderMath(op, inputA, inputB, scale, minimum, maximum, destination.baseAddress! + start, start, size)
                        start += size
                    }
                }
            }
        }
        return output
    }

    private let a: [Float] = [0.5, -0.5, 1, 0.25, -1, 0]
    private let b: [Float] = [0.25, 0.25, -0.5, 0.5, 0.5, 0.75]

    @Test func eachOperatorHasAKnownAnswer() {
        #expect(render(.add, a: a, b: b) == [0.75, -0.25, 0.5, 0.75, -0.5, 0.75])
        #expect(render(.subtract, a: a, b: b) == [0.25, -0.75, 1.5, -0.25, -1.5, -0.75])
        #expect(render(.multiply, a: a, b: b) == [0.125, -0.125, -0.5, 0.125, -0.5, 0])
        #expect(render(.divide, a: a, b: b) == [2, -2, -2, 0.5, -2, 0])
        #expect(render(.absolute, a: a, b: b) == [0.5, 0.5, 1, 0.25, 1, 0])
        #expect(render(.invert, a: a, b: b) == [-0.5, 0.5, -1, -0.25, 1, -0])
        #expect(render(.modulo, a: [1.5, -1.5, 0.75], b: [1, 1, 0.5]) == [0.5, -0.5, 0.25])
    }

    @Test func scaleMultipliesTheResult() {
        #expect(render(.add, a: a, b: b, scale: 2) == render(.add, a: a, b: b).map { $0 * 2 })
        #expect(render(.add, a: a, b: b, scale: -1) == render(.add, a: a, b: b).map { -$0 })
        #expect(render(.add, a: a, b: b, scale: 0).allSatisfy { $0 == 0 })
    }

    @Test func unwiredInputsReadZero() {
        #expect(render(.add, a: a) == a)
        #expect(render(.add, b: b) == b)
        #expect(render(.multiply, a: a).allSatisfy { $0 == 0 })
        #expect(render(.add, frames: 4) == [0, 0, 0, 0])
    }

    @Test func divisionAndModuloByZeroGiveZero() {
        for op in [Operator.divide, .modulo] {
            #expect(render(op, a: [1, -1, 1000], b: [0, 0, 0.0000001]) == [0, 0, 0])
            #expect(render(op, a: [1, 1], b: nil, frames: 2) == [0, 0])
        }
    }

    @Test func outputIsAlwaysFiniteAndWithinTheClamp() {
        let wild: [Float] = [.nan, .infinity, -.infinity, 3.4e38, -3.4e38, 1e-30, 0, 1]
        for op in [Operator.add, .subtract, .multiply, .divide, .absolute, .invert, .modulo] {
            for scale: Float in [-4, 4] {
                for (low, high) in [(Float(-16), Float(16)), (-1, 1), (0.25, 2)] {
                    let output = render(op, a: wild, b: wild.reversed(), scale: scale, minimum: low, maximum: high)
                    #expect(output.allSatisfy { $0.isFinite && $0 >= low && $0 <= high }, "\(op) \(low)…\(high)")
                }
            }
        }
    }

    @Test func theResultIsHeldBetweenClampMinAndClampMax() {
        let sum = render(.add, a: [0.5, -0.5, 3, -3, 20], b: [0.25, 0.25, 1, 1, 1])
        #expect(sum == [0.75, -0.25, 4, -2, 16])                                                 // wide by default
        #expect(render(.add, a: [0.5, -0.5, 3, -3, 20], b: [0.25, 0.25, 1, 1, 1], minimum: -1, maximum: 1) == [0.75, -0.25, 1, -1, 1])
        #expect(render(.add, a: [0.5, -0.5, 3, -3, 20], b: [0.25, 0.25, 1, 1, 1], minimum: 0.5, maximum: 2) == [0.75, 0.5, 2, 0.5, 2])
    }

    @Test func limitsGivenTheWrongWayRoundStillWork() {
        let input: [Float] = [-5, 0, 5]
        #expect(render(.add, a: input, minimum: 1, maximum: -1) == render(.add, a: input, minimum: -1, maximum: 1))
    }

    @Test func theClampSettingsChangeTheEngineRender() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wide = try await chain(operatorName: "add", scale: 4, directory: directory)
        let tight = try await chain(operatorName: "add", scale: 4, clamp: (-0.2, 0.2), directory: directory)
        #expect(wide != tight)
    }

    @Test func aShorterSourceHoldsItsLastValue() {
        #expect(render(.add, a: [1, 2], b: [10, 10, 10, 10]) == [11, 12, 12, 12])
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let x = sine(frequency: 3, frames: 5_000, amplitude: 1), y = sine(frequency: 7, frames: 5_000, amplitude: 1)
        for op in [Operator.add, .subtract, .multiply, .divide, .absolute, .invert, .modulo] {
            #expect(render(op, a: x, b: y, scale: 1.5, chunk: 777) == render(op, a: x, b: y, scale: 1.5))
        }
    }

    @Test func rendersAreBitIdentical() {
        let x = sine(frequency: 3, frames: 2_000, amplitude: 1), y = sine(frequency: 7, frames: 2_000, amplitude: 1)
        #expect(render(.divide, a: x, b: y) == render(.divide, a: x, b: y))
    }

    @Test func everyOperatorGivesADifferentResult() {
        let x = sine(frequency: 300, frames: 2_000, amplitude: 0.9), y = sine(frequency: 700, frames: 2_000, amplitude: 0.9)
        let operators: [Operator] = [.add, .subtract, .multiply, .divide, .absolute, .invert, .modulo]
        let results = operators.map { render($0, a: x, b: y) }
        for first in results.indices {
            for second in results.indices where second > first {
                #expect(results[first] != results[second], "\(operators[first]) vs \(operators[second])")
            }
        }
    }

    // MARK: end to end

    private enum Source { case unwired, long, short }

    /// LFO (a) and a second LFO (b) → Math → `mod.cutoff` of Filters on Audio → Filters → Print.
    private func chain(operatorName: String? = nil, scale: Double = 1, clamp: (Double, Double) = (-16, 16), secondSource: Source = .long, directory: URL, bypass: Bool = false) async throws -> [[Float]] {
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write([sine(frequency: 440, frames: 8_192)], to: source, sampleRate: 48_000)
        let shortAsset = AssetID(testUUID(9_400))
        let shortSource = directory.appendingPathComponent("short.wav")
        try TestAudio.write([sine(frequency: 5, frames: 2_000, amplitude: 0.9)], to: shortSource, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let lfoA = graph.add(.lfo, ["rate": .number(3)])
        let lfoB = graph.add(.lfo, ["rate": .number(5), "shape": .choice("triangle")])
        let math = graph.add(.math, ["operator": .choice(operatorName ?? "add"), "scale": .number(scale), "clampMin": .number(clamp.0), "clampMax": .number(clamp.1)])
        let filters = graph.add(.filters, ["cutoff": .number(700)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        let index = try #require(graph.project.nodes.firstIndex { $0.id == filters })
        graph.project.nodes[index].setModulated("cutoff", true)
        graph.connect(audio, to: filters)
        graph.connect(lfoA, to: math, "a")
        switch secondSource {
        case .long: graph.connect(lfoB, to: math, "b")
        case .short: graph.connect(graph.add(.audio, asset: shortAsset), to: math, "b")
        case .unwired: break
        }
        graph.connect(bypass ? lfoA : math, to: filters, "mod.cutoff")
        graph.connect(filters, to: print)
        let urls = [sourceAsset: source, shortAsset: shortSource]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        return try TestAudio.read(written).samples
    }

    @Test func mathBetweenTwoLFOsDrivesAFilterCutoff() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rendered = try await chain(operatorName: "multiply", directory: directory)
        let bypassed = try await chain(directory: directory, bypass: true)

        #expect(rendered.count == 1 && rendered[0].count == 8_192)
        #expect(rendered[0].allSatisfy { $0.isFinite })
        #expect(rendered != bypassed)
    }

    @Test func aShorterSourceOnBStaysFiniteAndFullLength() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rendered = try await chain(operatorName: "add", secondSource: .short, directory: directory)

        #expect(rendered.count == 1 && rendered[0].count == 8_192)
        #expect(rendered[0].allSatisfy { $0.isFinite })
    }

    @Test func theOperatorAndScaleSettingsChangeTheRender() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let add = try await chain(operatorName: "add", directory: directory)
        let subtract = try await chain(operatorName: "subtract", directory: directory)
        let halved = try await chain(operatorName: "add", scale: 0.5, directory: directory)

        #expect(add != subtract)
        #expect(add != halved)
    }

    @Test func pinsAndDefaultsAreAsDocumented() throws {
        let definition = NodeCatalog.definition(for: .math)
        #expect(definition.pins.map(\.id) == ["a", "b", "out"])
        #expect(definition.pins.allSatisfy { $0.signal == .control })
        #expect(definition.lengthRule == .followsConsumers)
        #expect(try #require(definition.parameter("operator")).defaultValue == .choice("add"))
        #expect(try #require(definition.parameter("scale")).defaultValue == .number(1))
        #expect(try #require(definition.parameter("clampMin")).defaultValue == .number(-16))
        #expect(try #require(definition.parameter("clampMax")).role == .setting)
    }
}
