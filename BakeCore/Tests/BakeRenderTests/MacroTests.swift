import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct MacroTests {
    private func render(
        value: Float, curve: bake.dsp.MacroCurve = .linear, depth: Float = 1,
        minimum: Float = 0, maximum: Float = 1, frames: Int = 2_000, chunk: Int? = nil
    ) -> [Float] {
        let valueSignal = signal(value, 0, 1)
        let curveSignal = signal(Float(curve.rawValue), 0, 2)
        let depthSignal = signal(depth, -1, 1)
        let minimumSignal = signal(minimum, 0, 1)
        let maximumSignal = signal(maximum, 0, 1)
        var output = [Float](repeating: 0, count: frames)
        output.withUnsafeMutableBufferPointer { destination in
            var start = 0
            while start < frames {
                let count = min(chunk ?? frames, frames - start)
                bake.dsp.renderMacro(valueSignal, curve, curveSignal, depthSignal, minimumSignal, maximumSignal,
                                     destination.baseAddress! + start, start, count)
                start += count
            }
        }
        return output
    }

    @Test func curvesMatchTheirKnownAnswers() {
        let linear = render(value: 0.5)[0]
        let exponential = render(value: 0.5, curve: .exponential)[0]
        let logarithmic = render(value: 0.5, curve: .logarithmic)[0]
        #expect(abs(linear - 0.5) < 1e-6)
        #expect(abs(exponential - Float((exp(2.0) - 1) / (exp(4.0) - 1))) < 1e-6)
        #expect(abs(logarithmic - Float(log(1 + (exp(4.0) - 1) / 2) / 4)) < 1e-6)
    }

    @Test func depthAndRangesHaveKnownAnswers() {
        #expect(render(value: 0.5, depth: -1)[0] == -0.5)
        #expect(render(value: 0, minimum: 0.2, maximum: 0.6)[0] == 0.2)
        #expect(render(value: 1, minimum: 0.2, maximum: 0.6)[0] == 0.6)
        #expect(render(value: 0.25, minimum: 0.8, maximum: 0.2)[0] == 0.65)
    }

    @Test func outputsAreChunkInvariantAndDeterministic() {
        let one = render(value: 0.371, curve: .logarithmic, depth: -0.75, minimum: 0.15, maximum: 0.91)
        #expect(render(value: 0.371, curve: .logarithmic, depth: -0.75, minimum: 0.15, maximum: 0.91, chunk: 777) == one)
        #expect(render(value: 0.371, curve: .logarithmic, depth: -0.75, minimum: 0.15, maximum: 0.91) == one)
    }

    @Test func extremesStayFiniteAndWithinModulationRange() {
        for value: Float in [0, 1] {
            for curve in [bake.dsp.MacroCurve.linear, .exponential, .logarithmic] {
                for depth: Float in [-1, 1] {
                    let output = render(value: value, curve: curve, depth: depth, minimum: 1, maximum: 0)
                    #expect(output.allSatisfy { $0.isFinite && (-1...1).contains($0) })
                }
            }
        }
    }

    @Test func macroOutputsAreControlSummaries() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("audio.wav")
        try TestAudio.write([[Float](repeating: 0.5, count: 8_192)], to: audioURL, sampleRate: 48_000)
        let asset = AssetID(testUUID(9_403))
        var graph = TestProject()
        let audio = graph.add(.audio, asset: asset)
        let macro = graph.add(.macro, ["value": .number(0.5)])
        let gain = graph.add(.gainVCA, ["mode": .choice("vca")])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: gain)
        graph.project.edges.append(Edge(from: PinRef(node: macro, pin: "out1"), to: PinRef(node: gain, pin: "amount")))
        graph.connect(gain, to: print)
        let directoryOut = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryOut, withIntermediateDirectories: true)
        let urls = [asset: audioURL]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls,
                                    outputDirectory: directoryOut, collectSummaries: true)
        let result = try await RenderEngine.render(request)
        #expect(result.summaries[PinRef(node: macro, pin: "out1")]?.isControl == true)
        #expect(result.summaries[PinRef(node: macro, pin: "out1")]?.spectrogram == nil)
    }

    @Test func macroOutputsHaveIndependentShaping() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("audio.wav")
        try TestAudio.write([[Float](repeating: 0.5, count: 8_192)], to: audioURL, sampleRate: 48_000)
        let asset = AssetID(testUUID(9_404))
        var graph = TestProject()
        let audio = graph.add(.audio, asset: asset)
        let macro = graph.add(.macro, [
            "value": .number(0.5), "outputs": .choice("2"),
            "depth1": .number(1), "min1": .number(0), "max1": .number(1), "curve1": .choice("linear"),
            "depth2": .number(-1), "min2": .number(0.2), "max2": .number(0.6), "curve2": .choice("logarithmic"),
        ])
        let gain1 = graph.add(.gainVCA, ["mode": .choice("vca")])
        let gain2 = graph.add(.gainVCA, ["mode": .choice("vca")])
        let print1 = graph.add(.print, ["bitDepth": .choice("32f")])
        let print2 = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: gain1)
        graph.connect(audio, to: gain2)
        graph.project.edges.append(Edge(from: PinRef(node: macro, pin: "out1"), to: PinRef(node: gain1, pin: "amount")))
        graph.project.edges.append(Edge(from: PinRef(node: macro, pin: "out2"), to: PinRef(node: gain2, pin: "amount")))
        graph.connect(gain1, to: print1)
        graph.connect(gain2, to: print2)
        let outputDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let urls = [asset: audioURL]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls,
                                    outputDirectory: outputDirectory, chunkFrames: 777)
        let result = try await RenderEngine.render(request)
        let output1 = try TestAudio.read(try #require(result.outputs[print1])).samples[0]
        let output2 = try TestAudio.read(try #require(result.outputs[print2])).samples[0]
        let logarithmic = log(1 + (exp(4.0) - 1) / 2) / 4
        #expect(output1.allSatisfy { abs($0 - 0.375) < 1e-6 })
        #expect(output2.allSatisfy { abs($0 - Float(0.5 * (1 - (0.2 + 0.4 * logarithmic)) / 2)) < 1e-6 })
    }

    @Test func definitionHasExpectedPinsAndGeneratedParameters() throws {
        let definition = NodeCatalog.definition(for: .macro)
        #expect(definition.pins.isEmpty)
        #expect(definition.repeated == [RepeatedPins(prefix: "out", direction: .output, signal: .control, count: .parameter("outputs"), channels: .mono)])
        #expect(definition.lengthRule == .followsConsumers)
        #expect(definition.parameters.count == 36)
        #expect(try #require(definition.parameter("value")).defaultValue == .number(0))
        #expect(try #require(definition.parameter("label")).defaultValue == .text("Macro"))
        #expect(try #require(definition.parameter("outputs")).defaultValue == .choice("1"))
        for index in 1...8 {
            for id in ["depth\(index)", "min\(index)", "max\(index)", "curve\(index)"] {
                #expect(try #require(definition.parameter(id)).isModulatable, "parameter is modulatable: \(id)")
            }
        }
        #expect(definition.parameter("outputs")?.isModulatable == false)
        #expect(definition.parameter("widget")?.isModulatable == false)
    }

    @Test func macroCanSweepAFilterAcrossItsFullRange() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write([sine(frequency: 440, frames: 8_192)], to: source, sampleRate: 48_000)
        let urls = [sourceAsset: source]
        let controlled = try await filterChain(withMacro: true, directory: directory, assetURLs: urls)
        let fixed = try await filterChain(withMacro: false, directory: directory, assetURLs: urls)
        #expect(controlled.count == fixed.count && controlled[0].count == 8_192)
        #expect(zip(controlled[0], fixed[0]).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func macroValueAcceptsLFOAnotherMacroAndShortAudioModulators() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let longURL = directory.appendingPathComponent("long.wav")
        let shortURL = directory.appendingPathComponent("short.wav")
        try TestAudio.write([[Float](repeating: 0.5, count: 96_000)], to: longURL, sampleRate: 48_000)
        try TestAudio.write([[Float](repeating: 0.25, count: 4_800)], to: shortURL, sampleRate: 48_000)
        let longAsset = AssetID(testUUID(9_401))
        let shortAsset = AssetID(testUUID(9_402))
        let assets = [longAsset: longURL, shortAsset: shortURL]

        let lfoResult = try await modulationChain(source: .lfo, assets: assets, longAsset: longAsset,
                                                  shortAsset: shortAsset, directory: directory)
        #expect(lfoResult.frames == 96_000)
        #expect(lfoResult.longAudio.allSatisfy { $0.isFinite })
        #expect(lfoResult.isControl && lfoResult.hasNoSpectrogram)
        #expect(Set(lfoResult.longAudio.prefix(48_000)).count > 1)

        let macroResult = try await modulationChain(source: .macro, assets: assets, longAsset: longAsset,
                                                    shortAsset: shortAsset, directory: directory)
        #expect(macroResult.frames == 96_000)
        #expect(macroResult.longAudio.allSatisfy { $0.isFinite })
        #expect(macroResult.isControl && macroResult.hasNoSpectrogram)
        #expect(macroResult.longAudio.allSatisfy { $0.isFinite && abs($0) > 1e-5 })

        let shortSourceResult = try await modulationChain(source: .shortAudio, assets: assets, longAsset: longAsset,
                                                          shortAsset: shortAsset, directory: directory)
        #expect(shortSourceResult.frames == 96_000)
        #expect(shortSourceResult.longAudio.allSatisfy { $0.isFinite })
        #expect(shortSourceResult.isControl && shortSourceResult.hasNoSpectrogram)
        #expect(shortSourceResult.longAudio.suffix(48_000).allSatisfy { $0.isFinite && abs($0) > 1e-5 })
        #expect(shortSourceResult.longAudio.suffix(48_000).allSatisfy { abs($0 - 0.4375) < 1e-6 })
    }

    private enum ValueSource { case lfo, macro, shortAudio }

    private func modulationChain(source: ValueSource, assets: [AssetID: URL], longAsset: AssetID,
                                 shortAsset: AssetID, directory: URL) async throws -> (frames: Int, longAudio: [Float], shortAudio: [Float], isControl: Bool, hasNoSpectrogram: Bool) {
        var graph = TestProject()
        let longAudio = graph.add(.audio, asset: longAsset)
        let shortAudio = graph.add(.audio, asset: shortAsset)
        let macro = graph.add(.macro, ["value": .number(0.5), "outputs": .choice("2")], modulated: ["value"])
        let longGain = graph.add(.gainVCA, ["mode": .choice("vca")])
        let shortGain = graph.add(.gainVCA, ["mode": .choice("vca")])
        let longPrint = graph.add(.print, ["bitDepth": .choice("32f")])
        let shortPrint = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(longAudio, to: longGain)
        graph.connect(shortAudio, to: shortGain)
        graph.connect(longGain, to: longPrint)
        graph.connect(shortGain, to: shortPrint)
        graph.project.edges.append(Edge(from: PinRef(node: macro, pin: "out1"), to: PinRef(node: longGain, pin: "amount")))
        graph.project.edges.append(Edge(from: PinRef(node: macro, pin: "out2"), to: PinRef(node: shortGain, pin: "amount")))
        switch source {
        case .lfo:
            let lfo = graph.add(.lfo, ["rate": .number(3)])
            graph.project.edges.append(Edge(from: PinRef(node: lfo, pin: "out"), to: PinRef(node: macro, pin: "mod.value")))
        case .macro:
            let upstream = graph.add(.macro, ["value": .number(0.25)])
            graph.project.edges.append(Edge(from: PinRef(node: upstream, pin: "out1"), to: PinRef(node: macro, pin: "mod.value")))
        case .shortAudio:
            graph.project.edges.append(Edge(from: PinRef(node: shortAudio, pin: "out"), to: PinRef(node: macro, pin: "mod.value")))
        }
        let plan = try compile(graph.project, assetURLs: assets)
        let macroStep = try #require(plan.steps.first { $0.node == macro })
        let outputDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let request = RenderRequest(plan: plan, assetURLs: assets, outputDirectory: outputDirectory,
                                    chunkFrames: 777, collectSummaries: true)
        let result = try await RenderEngine.render(request)
        let summary = try #require(result.summaries[PinRef(node: macro, pin: "out1")])
        return (
            macroStep.shape.frames,
            try TestAudio.read(try #require(result.outputs[longPrint])).samples[0],
            try TestAudio.read(try #require(result.outputs[shortPrint])).samples[0],
            summary.isControl,
            summary.spectrogram == nil
        )
    }

    private func filterChain(withMacro: Bool, directory: URL, assetURLs: [AssetID: URL]) async throws -> [[Float]] {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let filters = graph.add(.filters, ["cutoff": .number(withMacro ? 20 : 20_000)])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: filters)
        if withMacro {
            let macro = graph.add(.macro, ["value": .number(1)])
            let filterIndex = try #require(graph.project.nodes.firstIndex { $0.id == filters })
            graph.project.nodes[filterIndex].setModulated("cutoff", true)
            graph.project.edges.append(Edge(from: PinRef(node: macro, pin: "out1"), to: PinRef(node: filters, pin: "mod.cutoff")))
        }
        graph.connect(filters, to: print)
        let output = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: assetURLs), assetURLs: assetURLs, outputDirectory: output)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }
}
