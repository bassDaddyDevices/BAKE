import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct LogicTests {
    private typealias Operator = bake.dsp.LogicOperator
    private let all: [Operator] = [.threshold, .andGate, .orGate, .xorGate, .notGate]

    /// `a` and `b` nil = unwired. `chunk` renders in pieces (carrying the gate's memory) to check chunk invariance.
    /// `thresholdModulation` moves the threshold (trim 1: threshold = base + modulation × 2).
    private func render(
        _ op: Operator, a: [Float]? = nil, b: [Float]? = nil, threshold: Float = 0.5, hysteresis: Float = 0, hold: Int = 0,
        thresholdModulation: [Float]? = nil, frames: Int? = nil, chunk: Int? = nil
    ) -> [Float] {
        let count = frames ?? max(a?.count ?? 0, b?.count ?? 0)
        var output = [Float](repeating: 0, count: count)
        let aValues = a ?? [], bValues = b ?? [], modulation = thresholdModulation ?? []
        var state = bake.dsp.LogicState()
        aValues.withUnsafeBufferPointer { aPointer in
            bValues.withUnsafeBufferPointer { bPointer in
                modulation.withUnsafeBufferPointer { modulationPointer in
                    output.withUnsafeMutableBufferPointer { destination in
                        var inputA = bake.dsp.ControlInput(), inputB = bake.dsp.ControlInput()
                        if a != nil { inputA.samples = aPointer.baseAddress; inputA.frames = aPointer.count }
                        if b != nil { inputB.samples = bPointer.baseAddress; inputB.frames = bPointer.count }
                        var level = signal(threshold, -1, 1)
                        if thresholdModulation != nil { level.modulation = modulationPointer.baseAddress; level.modulationFrames = modulationPointer.count }
                        var start = 0
                        while start < count {
                            let size = min(chunk ?? count, count - start)
                            bake.dsp.renderLogic(&state, op, inputA, inputB, level, hysteresis, hold, destination.baseAddress! + start, start, size)
                            start += size
                        }
                    }
                }
            }
        }
        return output
    }

    // The four combinations of (a, b) low/high, in truth-table order.
    private let a: [Float] = [0, 0, 1, 1]
    private let b: [Float] = [0, 1, 0, 1]

    @Test func eachOperatorMatchesItsTruthTable() {
        #expect(render(.threshold, a: a, b: b) == [0, 0, 1, 1])
        #expect(render(.andGate, a: a, b: b) == [0, 0, 0, 1])
        #expect(render(.orGate, a: a, b: b) == [0, 1, 1, 1])
        #expect(render(.xorGate, a: a, b: b) == [0, 1, 1, 0])
        #expect(render(.notGate, a: a, b: b) == [1, 1, 0, 0])
    }

    @Test func aLevelCountsAsHighOnlyAboveTheThreshold() {
        let ramp: [Float] = [-1, 0, 0.25, 0.5, 0.5001, 1]
        #expect(render(.threshold, a: ramp) == [0, 0, 0, 0, 1, 1])
        #expect(render(.threshold, a: ramp, threshold: -0.5) == [0, 1, 1, 1, 1, 1])
        #expect(render(.threshold, a: ramp, threshold: 1) == [0, 0, 0, 0, 0, 0])
        #expect(render(.notGate, a: ramp) == [1, 1, 1, 1, 0, 0])
    }

    @Test func outputIsExactlyZeroOrOne() {
        let x = sine(frequency: 3, frames: 5_000, amplitude: 1), y = sine(frequency: 7, frames: 5_000, amplitude: 1)
        for op in all {
            #expect(render(op, a: x, b: y, threshold: 0.1).allSatisfy { $0 == 0 || $0 == 1 }, "\(op)")
        }
    }

    @Test func unwiredInputsAreLow() {
        #expect(render(.threshold, frames: 3) == [0, 0, 0])
        #expect(render(.andGate, a: a) == [0, 0, 0, 0])
        #expect(render(.orGate, a: a) == a)
        #expect(render(.notGate, frames: 3) == [1, 1, 1])
    }

    @Test func nonFiniteInputsAreLowAndTheOutputStaysAGate() {
        let wild: [Float] = [.nan, .infinity, -.infinity, 3.4e38, -3.4e38, 0, 1]
        for op in all {
            for level: Float in [-1, 1] {
                #expect(render(op, a: wild, b: wild.reversed(), threshold: level).allSatisfy { $0 == 0 || $0 == 1 }, "\(op)")
            }
        }
    }

    @Test func aShorterSourceHoldsItsLastValue() {
        #expect(render(.andGate, a: [1, 1, 1, 1], b: [0, 1]) == [0, 1, 1, 1])
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let x = sine(frequency: 3, frames: 5_000, amplitude: 1), y = sine(frequency: 7, frames: 5_000, amplitude: 1)
        for op in all {
            #expect(render(op, a: x, b: y, threshold: 0.2, chunk: 777) == render(op, a: x, b: y, threshold: 0.2))
            // With the gate's memory in play (hysteresis and hold) the chunks must still agree.
            #expect(render(op, a: x, b: y, threshold: 0.2, hysteresis: 0.05, hold: 40, chunk: 777)
                == render(op, a: x, b: y, threshold: 0.2, hysteresis: 0.05, hold: 40))
        }
    }

    @Test func aMovingThresholdMovesTheGate() {
        let level = [Float](repeating: 0.4, count: 8)
        let sweep: [Float] = [0.25, 0.25, 0.25, 0.25, -0.25, -0.25, -0.25, -0.25]   // threshold 0.5 ± 0.5
        #expect(render(.threshold, a: level, thresholdModulation: sweep) == [0, 0, 0, 0, 1, 1, 1, 1])
    }

    @Test func hysteresisStopsANoisySignalChattering() {
        let noisy = (0..<400).map { Float(0.5 + 0.1 * sin(Double($0) * 2.7) * cos(Double($0) * 0.9)) }
        func edges(_ gate: [Float]) -> Int { zip(gate, gate.dropFirst()).filter { $0 != $1 }.count }
        #expect(edges(render(.threshold, a: noisy)) > 20)
        #expect(edges(render(.threshold, a: noisy, hysteresis: 0.1)) == 0)
    }

    @Test func hysteresisKeepsItsStateInTheDeadBand() {
        let swing: [Float] = [0, 0.45, 0.55, 0.65, 0.55, 0.45, 0.35, 0.45]
        #expect(render(.threshold, a: swing, hysteresis: 0.1) == [0, 0, 0, 1, 1, 1, 0, 0])
    }

    @Test func holdKeepsTheGateHighAfterItFalls() {
        let pulse: [Float] = [0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]
        #expect(render(.threshold, a: pulse, hold: 3) == [0, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1])
        #expect(render(.threshold, a: pulse, hold: 0) == pulse)
    }

    @Test func rendersAreBitIdentical() {
        let x = sine(frequency: 3, frames: 2_000, amplitude: 1), y = sine(frequency: 7, frames: 2_000, amplitude: 1)
        #expect(render(.xorGate, a: x, b: y) == render(.xorGate, a: x, b: y))
    }

    @Test func everyOperatorAndTheThresholdChangeTheResult() {
        let x = sine(frequency: 300, frames: 2_000, amplitude: 0.9), y = sine(frequency: 700, frames: 2_000, amplitude: 0.9)
        let results = all.map { render($0, a: x, b: y) }
        for first in results.indices {
            for second in results.indices where second > first {
                #expect(results[first] != results[second], "\(all[first]) vs \(all[second])")
            }
        }
        #expect(render(.threshold, a: x, threshold: 0.2) != render(.threshold, a: x, threshold: 0.7))
    }

    // MARK: end to end

    private enum Source { case unwired, long, short }

    /// LFO (a) and a second LFO (b) → Logic → `mod.cutoff` of Filters on Audio → Filters → Print.
    private func chain(operatorName: String = "and", threshold: Double = 0.5, hold: Double = 0, secondSource: Source = .long, directory: URL, bypass: Bool = false) async throws -> [[Float]] {
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write([sine(frequency: 440, frames: 8_192)], to: source, sampleRate: 48_000)
        let shortAsset = AssetID(testUUID(9_500))
        let shortSource = directory.appendingPathComponent("short.wav")
        try TestAudio.write([sine(frequency: 5, frames: 2_000, amplitude: 0.9)], to: shortSource, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let lfoA = graph.add(.lfo, ["rate": .number(3)])
        let lfoB = graph.add(.lfo, ["rate": .number(5), "shape": .choice("triangle")])
        let logic = graph.add(.logic, ["operator": .choice(operatorName), "threshold": .number(threshold), "holdTime": .number(hold)])
        let filters = graph.add(.filters, ["cutoff": .number(700)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        let index = try #require(graph.project.nodes.firstIndex { $0.id == filters })
        graph.project.nodes[index].setModulated("cutoff", true)
        graph.connect(audio, to: filters)
        graph.connect(lfoA, to: logic, "a")
        switch secondSource {
        case .long: graph.connect(lfoB, to: logic, "b")
        case .short: graph.connect(graph.add(.audio, asset: shortAsset), to: logic, "b")
        case .unwired: break
        }
        graph.connect(bypass ? lfoA : logic, to: filters, "mod.cutoff")
        graph.connect(filters, to: print)
        let urls = [sourceAsset: source, shortAsset: shortSource]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        return try TestAudio.read(written).samples
    }

    @Test func aGateFromTwoLFOsDrivesAFilterCutoff() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rendered = try await chain(operatorName: "and", directory: directory)
        let bypassed = try await chain(directory: directory, bypass: true)

        #expect(rendered.count == 1 && rendered[0].count == 8_192)
        #expect(rendered[0].allSatisfy { $0.isFinite })
        #expect(rendered != bypassed)
    }

    @Test func aShorterSourceOnBStaysFiniteAndFullLength() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rendered = try await chain(operatorName: "or", secondSource: .short, directory: directory)

        #expect(rendered.count == 1 && rendered[0].count == 8_192)
        #expect(rendered[0].allSatisfy { $0.isFinite })
    }

    @Test func theOperatorAndThresholdSettingsChangeTheRender() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let and = try await chain(operatorName: "and", directory: directory)
        let xor = try await chain(operatorName: "xor", directory: directory)
        let lower = try await chain(operatorName: "and", threshold: -0.5, directory: directory)

        #expect(and != xor)
        #expect(and != lower)
    }

    @Test func hysteresisAndHoldChangeTheEngineRender() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = try await chain(operatorName: "threshold", directory: directory)
        let held = try await chain(operatorName: "threshold", hold: 0.05, directory: directory)
        #expect(plain != held)
    }

    @Test func pinsAndDefaultsAreAsDocumented() throws {
        let definition = NodeCatalog.definition(for: .logic)
        #expect(try #require(definition.parameter("threshold")).isModulatable)
        #expect(try #require(definition.parameter("hysteresis")).role == .setting)
        #expect(try #require(definition.parameter("holdTime")).defaultValue == .number(0))
        #expect(definition.pins.map(\.id) == ["a", "b", "out"])
        #expect(definition.pins.allSatisfy { $0.signal == .control })
        #expect(definition.lengthRule == .followsConsumers)
        #expect(try #require(definition.parameter("operator")).defaultValue == .choice("threshold"))
        #expect(try #require(definition.parameter("threshold")).defaultValue == .number(0.5))
    }
}
