import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct WavetableFactoryTests {
    private func settings(frameSize: Int = 256, slots: Int = 3,
                         morph: bake.dsp.WavetableMorph = .linear,
                         phase: bake.dsp.WavetablePhase = .keep,
                         normalize: bake.dsp.WavetableNormalize = .off,
                         snap: bake.dsp.WavetableToggle = .off,
                         dcRemoval: bake.dsp.WavetableToggle = .off,
                         fragments: Int = 8, seed: UInt64 = 1) -> bake.dsp.WavetableSettings {
        var value = bake.dsp.WavetableSettings()
        value.frameSize = frameSize
        value.slots = slots
        value.morph = morph
        value.phase = phase
        value.normalize = normalize
        value.snap = snap
        value.dcRemoval = dcRemoval
        value.fragments = fragments
        value.seed = seed
        return value
    }

    private func build(_ sourceFrames: [[Float]], settings: bake.dsp.WavetableSettings) -> [Float] {
        let sourceSamples = sourceFrames.flatMap { $0 }
        var input = bake.dsp.AudioInput()
        var output = [Float](repeating: 0, count: settings.frameSize * settings.slots)
        let capacity = Int(bake.dsp.wavetableMaxSourceFrames) * settings.frameSize
        var gathered = [Float](repeating: 0, count: capacity)
        var scratch = [Double](repeating: 0, count: Int(bake.dsp.wavetableFFTWorkspaceDoubles(settings.frameSize)))
        let outputCount = output.count
        sourceSamples.withUnsafeBufferPointer { pointer in
            input.channels.0 = pointer.baseAddress
            input.channelCount = 1
            input.frames = pointer.count
            gathered.withUnsafeMutableBufferPointer { gatheredPointer in
                scratch.withUnsafeMutableBufferPointer { scratchPointer in
                    output.withUnsafeMutableBufferPointer { outputPointer in
                        bake.dsp.buildWavetable(settings, [input], 1, gatheredPointer.baseAddress!, gatheredPointer.count,
                                                outputPointer.baseAddress!, scratchPointer.baseAddress!)
                    }
                }
            }
        }
        return Array(output.prefix(outputCount))
    }

    @Test func linearThreeSlotMidpointIsTheAverageBeforeConditioning() {
        let size = 256
        let a = (0..<size).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
        let b = (0..<size).map { Float(2 * Double($0) / Double(size) - 1) }
        let output = build([a, b], settings: settings(frameSize: size, slots: 3))
        for sample in 0..<size {
            #expect(abs(output[size + sample] - (a[sample] + b[sample]) / 2) < 1e-6)
        }
        #expect(Array(output[0..<size]) == a)
        #expect(Array(output[(2 * size)..<(3 * size)]) == b)
    }

    @Test func aShortInputBecomesOneZeroPaddedSourceFrame() {
        let source: [Float] = [0.25, -0.25, 0.5]
        let output = build([source], settings: settings(frameSize: 256, slots: 3))
        for slot in 0..<3 {
            #expect(output[slot * 256] == source[0])
            #expect(output[(slot + 1) * 256 - 1] == 0)
        }
    }

    @Test func spectralAndFragmentMorphsAreSeededAndDistinct() {
        let size = 256
        let a = (0..<size).map { Float(sin(2 * Double.pi * 3 * Double($0) / Double(size))) }
        let b = (0..<size).map { Float(sin(2 * Double.pi * 11 * Double($0) / Double(size))) }
        for mode in [bake.dsp.WavetableMorph.spectral, .fragments] {
            let control = settings(frameSize: size, slots: 5, morph: mode, seed: 19)
            let first = build([a, b], settings: control)
            #expect(build([a, b], settings: control) == first)
            #expect(build([a, b], settings: settings(frameSize: size, slots: 5, morph: mode, seed: 20)) != first)
        }
    }

    @Test func zeroSnapAndPerFrameNormalizationMeetTheirKnownAnswers() {
        let size = 256
        let wave = (0..<size).map { Float(sin(2 * Double.pi * (Double($0) + 0.3) / Double(size))) * 0.2 }
        let snapped = build([wave], settings: settings(frameSize: size, slots: 3, snap: .on))
        for slot in 0..<3 {
            #expect(abs(snapped[slot * size]) < 0.02)
            let crossings = (0..<size).filter { index in
                let next = (index + 1) % size
                return snapped[slot * size + index] <= 0 && snapped[slot * size + next] > 0
            }
            #expect(crossings.contains(0) || crossings.contains(size - 1))
        }
        let normalized = build([wave], settings: settings(frameSize: size, slots: 3, normalize: .perFrame))
        for slot in 0..<3 {
            let peak = normalized[(slot * size)..<((slot + 1) * size)].map { abs($0) }.max() ?? 0
            #expect(abs(peak - 1) < 1e-6)
        }
    }

    @Test func everyConditioningSettingChangesTheGeneratedTable() {
        let size = 256
        let a = (0..<size).map { Float(sin(2 * Double.pi * 3 * Double($0) / Double(size)) + 0.2) * 0.25 }
        let b = (0..<size).map { Float(sin(2 * Double.pi * 7 * Double($0) / Double(size)) + 0.4) * 0.3 }
        let baseline = build([a, b], settings: settings(frameSize: size, slots: 3))
        #expect(build([a, b], settings: settings(frameSize: size, slots: 3, dcRemoval: .on)) != baseline)
        #expect(build([a, b], settings: settings(frameSize: size, slots: 3, snap: .on)) != baseline)
        #expect(build([a, b], settings: settings(frameSize: size, slots: 3, phase: .align)) != baseline)
        #expect(build([a, b], settings: settings(frameSize: size, slots: 3, phase: .minimumCrest)) != baseline)
        #expect(build([a, b], settings: settings(frameSize: size, slots: 3, phase: .random)) != baseline)
        #expect(build([a, b], settings: settings(frameSize: size, slots: 3, normalize: .perFrame)) != baseline)
        #expect(build([a, b], settings: settings(frameSize: size, slots: 3, normalize: .table)) != baseline)
        #expect(build([a, b], settings: settings(frameSize: size, slots: 3, morph: .fragments, fragments: 4)) != baseline)
        #expect(build([a, b], settings: settings(frameSize: size, slots: 3, morph: .fragments, fragments: 16)) != baseline)
    }

    @Test func chunksCopyOneWholeTableIdentically() {
        let size = 256
        let a = (0..<size * 2).map { Float(sin(2 * Double.pi * 5 * Double($0 % size) / Double(size))) }
        let b = (0..<size * 2).map { Float(sin(2 * Double.pi * 13 * Double($0 % size) / Double(size))) }
        let configured = settings(frameSize: size, slots: 7, morph: .spectral, seed: 8)
        let expected = build([a, b], settings: configured)
        var inputs = [bake.dsp.AudioInput(), bake.dsp.AudioInput()]
        var output = [Float](repeating: 0, count: expected.count)
        let outputCount = output.count
        var gathered = [Float](repeating: 0, count: Int(bake.dsp.wavetableMaxSourceFrames) * size)
        var scratch = [Double](repeating: 0, count: Int(bake.dsp.wavetableFFTWorkspaceDoubles(size)))
        a.withUnsafeBufferPointer { aPointer in
            b.withUnsafeBufferPointer { bPointer in
                inputs[0].channels.0 = aPointer.baseAddress
                inputs[0].channelCount = 1
                inputs[0].frames = aPointer.count
                inputs[1].channels.0 = bPointer.baseAddress
                inputs[1].channelCount = 1
                inputs[1].frames = bPointer.count
                gathered.withUnsafeMutableBufferPointer { gatheredPointer in
                    scratch.withUnsafeMutableBufferPointer { scratchPointer in
                        output.withUnsafeMutableBufferPointer { outputPointer in
                            bake.dsp.buildWavetable(configured, inputs, inputs.count,
                                                    gatheredPointer.baseAddress!, gatheredPointer.count,
                                                    outputPointer.baseAddress!, scratchPointer.baseAddress!)
                        }
                    }
                }
            }
        }
        #expect(output == expected)
        #expect(output.allSatisfy { $0.isFinite })
        #expect(outputCount == size * 7)
    }

    @Test func factoryRendersTwoAssetsToThePlannedMonoTable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let size = 256
        let sineAsset = AssetID(testUUID(9_501))
        let sawAsset = AssetID(testUUID(9_502))
        let sineFile = directory.appendingPathComponent("sine.wav")
        let sawFile = directory.appendingPathComponent("saw.wav")
        let sineCycle = (0..<size).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
        let sawCycle = (0..<size).map { Float(2 * Double($0) / Double(size) - 1) }
        try TestAudio.write([sineCycle + sineCycle], to: sineFile, sampleRate: 48_000)
        try TestAudio.write([sawCycle + sawCycle], to: sawFile, sampleRate: 48_000)
        let assets = [sineAsset: sineFile, sawAsset: sawFile]
        let rendered = try await renderFactory(assets: assets, sineAsset: sineAsset, sawAsset: sawAsset,
                                               directory: directory, slots: 3, chunkFrames: 777)
        #expect(rendered.output.count == 1 && rendered.output[0].count == size * 3)
        #expect(rendered.planFrames == size * 3)
        #expect(rendered.output[0].allSatisfy { $0.isFinite })
        for sample in 0..<size {
            #expect(abs(rendered.output[0][size + sample] - (sineCycle[sample] + sawCycle[sample]) / 2) < 1e-6)
        }
        let declared = try await renderFactory(assets: assets, sineAsset: sineAsset, sawAsset: sawAsset,
                                              directory: directory, slots: 3, chunkFrames: 777, wavetableFrames: "2048")
        #expect(declared.output == rendered.output)
        let declaredBytes = try Data(contentsOf: declared.url)
        #expect(String(decoding: declaredBytes, as: UTF8.self).contains("<!>2048 10000000 wavetable (bake)"))
    }

    @Test func factoryRenderIsChunkInvariant() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let size = 256
        let sineAsset = AssetID(testUUID(9_503))
        let sawAsset = AssetID(testUUID(9_504))
        let sineFile = directory.appendingPathComponent("sine.wav")
        let sawFile = directory.appendingPathComponent("saw.wav")
        let sineCycle = (0..<size).map { Float(sin(2 * Double.pi * 5 * Double($0) / Double(size))) }
        let sawCycle = (0..<size).map { Float(2 * Double($0) / Double(size) - 1) }
        try TestAudio.write([Array(repeating: sineCycle, count: 8).flatMap { $0 }], to: sineFile, sampleRate: 48_000)
        try TestAudio.write([Array(repeating: sawCycle, count: 8).flatMap { $0 }], to: sawFile, sampleRate: 48_000)
        let assets = [sineAsset: sineFile, sawAsset: sawFile]
        let chunked = try await renderFactory(assets: assets, sineAsset: sineAsset, sawAsset: sawAsset,
                                              directory: directory, slots: 17, chunkFrames: 777, mode: "spectral")
        let whole = try await renderFactory(assets: assets, sineAsset: sineAsset, sawAsset: sawAsset,
                                            directory: directory, slots: 17, chunkFrames: 65_536, mode: "spectral")
        #expect(chunked.output == whole.output)
        #expect(chunked.output[0].allSatisfy { $0.isFinite })
    }

    private func renderFactory(assets: [AssetID: URL], sineAsset: AssetID, sawAsset: AssetID,
                               directory: URL, slots: Int, chunkFrames: Int, mode: String = "linear",
                               wavetableFrames: String = "off") async throws -> (output: [[Float]], planFrames: Int, url: URL) {
        var graph = TestProject()
        let sine = graph.add(.audio, asset: sineAsset)
        let saw = graph.add(.audio, asset: sawAsset)
        let factory = graph.add(.wavetableFactory, [
            "frameSize": .choice("256"), "slots": .number(Double(slots)),
            "morphMode": .choice(mode), "snap": .choice("off"),
            "dcRemoval": .choice("off"), "normalize": .choice("off"),
        ])
        let print = graph.add(.print, ["bitDepth": .choice("32f"), "wavetable": .choice(wavetableFrames)])
        graph.connect(sine, to: factory, "in1")
        graph.connect(saw, to: factory, "in2")
        graph.connect(factory, to: print)
        let outputDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let plan = try compile(graph.project, assetURLs: assets)
        let planFrames = try #require(plan.steps.first { $0.node == factory }?.shape.frames)
        let request = RenderRequest(plan: plan, assetURLs: assets, outputDirectory: outputDirectory, chunkFrames: chunkFrames)
        let url = try #require(try await RenderEngine.render(request).outputs[print])
        return (try TestAudio.read(url).samples, planFrames, url)
    }

    @Test func factoryAllSettingsStayWithinFiniteOutputAtExtremes() {
        let size = 256
        let a = (0..<size).map { Float(sin(2 * Double.pi * 3 * Double($0) / Double(size))) }
        let b = (0..<size).map { Float(cos(2 * Double.pi * 7 * Double($0) / Double(size))) }
        for morph in [bake.dsp.WavetableMorph.linear, .spectral, .fragments] {
            for phase in [bake.dsp.WavetablePhase.keep, .align, .minimumCrest, .random] {
                for normalize in [bake.dsp.WavetableNormalize.off, .perFrame, .table] {
                    let output = build([a, b], settings: settings(frameSize: size, slots: 3, morph: morph, phase: phase,
                                                                  normalize: normalize, snap: .on, dcRemoval: .on,
                                                                  fragments: 32, seed: 65_535))
                    #expect(output.allSatisfy { $0.isFinite })
                }
            }
        }
    }

    @Test func factoryRejectsAnAllUnwiredInputSet() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var graph = TestProject()
        let factory = graph.add(.wavetableFactory, ["frameSize": .choice("256"), "slots": .number(3)])
        let print = graph.add(.print)
        graph.connect(factory, to: print)
        #expect(throws: CompileFailure.self) {
            try compile(graph.project, assetURLs: [:])
        }
    }

    @Test func factoryCatalogUsesGrowingInputsAndFixedGeneratedLength() throws {
        let definition = NodeCatalog.definition(for: .wavetableFactory)
        #expect(definition.pins.map(\.id) == ["out"])
        #expect(definition.repeated.count == 1)
        #expect(definition.needsAnyInput)
        #expect(definition.lengthRule == .generated(frameSize: "frameSize", count: "slots"))
        #expect(definition.parameters.allSatisfy { !$0.isModulatable })
        #expect(definition.parameter("inputCount")?.role == .hidden)
    }

    /// Source cycles beyond the old 1,024 limit are used when the patch asks for the whole input, and
    /// ignored (as before) when it doesn't.
    @Test func wholeInputKeepsEveryCycleAndTheOldLimitStillCutsAt1024() {
        let size = 256
        let cycles = 1_100
        let source = (0..<cycles).flatMap { cycle in [Float](repeating: Float(cycle) / 2_000, count: size) }
        func lastSlotValue(maxSourceFrames: Int) -> Float {
            var configured = settings(frameSize: size, slots: 2)
            configured.maxSourceFrames = maxSourceFrames
            var input = bake.dsp.AudioInput()
            var output = [Float](repeating: 0, count: size * 2)
            var gathered = [Float](repeating: 0, count: max(maxSourceFrames, 1_024) * size)
            var scratch = [Double](repeating: 0, count: Int(bake.dsp.wavetableFFTWorkspaceDoubles(size)))
            source.withUnsafeBufferPointer { pointer in
                input.channels.0 = pointer.baseAddress
                input.channelCount = 1
                input.frames = pointer.count
                gathered.withUnsafeMutableBufferPointer { gatheredPointer in
                    scratch.withUnsafeMutableBufferPointer { scratchPointer in
                        output.withUnsafeMutableBufferPointer { outputPointer in
                            bake.dsp.buildWavetable(configured, [input], 1, gatheredPointer.baseAddress!, gatheredPointer.count,
                                                    outputPointer.baseAddress!, scratchPointer.baseAddress!)
                        }
                    }
                }
            }
            return output[2 * size - 1]
        }
        #expect(lastSlotValue(maxSourceFrames: Int(bake.dsp.wavetableMaxSourceFrames)) == Float(1_023) / 2_000)
        #expect(lastSlotValue(maxSourceFrames: cycles) == Float(cycles - 1) / 2_000)
    }
}
