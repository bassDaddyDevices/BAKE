import Foundation
import Testing
@testable import BakeGraph

struct NodeCatalogTests {
    @Test(arguments: NodeKind.allCases)
    func everyKindHasADefinition(kind: NodeKind) {
        #expect(NodeCatalog.definition(for: kind).kind == kind)
    }

    @Test(arguments: NodeKind.allCases)
    func lengthChangingParametersAreNeverModulatable(kind: NodeKind) {
        // Buffer sizes are fixed at compile time, so a parameter that scales length can't vary over time.
        let definition = NodeCatalog.definition(for: kind)
        if case .scaledInput(_, let parameter) = definition.lengthRule {
            #expect(definition.parameter(parameter)?.isModulatable == false)
        }
        if case .looped = definition.lengthRule {
            for parameter in LooperPlan.lengthParameters {
                #expect(definition.parameter(parameter)?.isModulatable == false, "\(parameter)")
            }
        }
    }

    @Test(arguments: NodeKind.allCases)
    func wholeNumberParametersHaveWholeNumberRangesAndDefaults(kind: NodeKind) {
        for parameter in NodeCatalog.definition(for: kind).parameters where parameter.isInteger {
            guard case .number(let range, let defaultValue, _) = parameter.kind else {
                Issue.record("\(parameter.id) is whole-number but not a number")
                continue
            }
            #expect(range.lowerBound.rounded() == range.lowerBound && range.upperBound.rounded() == range.upperBound, "\(parameter.id)")
            #expect(defaultValue.rounded() == defaultValue, "\(parameter.id)")
        }
    }

    @Test func countsAreWholeNumbersAndTempoIsNot() {
        #expect(NodeCatalog.definition(for: .stepFX).parameter("steps")?.isInteger == true)
        #expect(NodeCatalog.definition(for: .redux).parameter("bitDepth")?.isInteger == false)
        #expect(NodeCatalog.definition(for: .resonator).parameter("bands")?.isInteger == true)
        #expect(NodeCatalog.definition(for: .clock).parameter("bpm")?.isInteger == false)
        #expect(NodeCatalog.definition(for: .stutter).parameter("gate")?.isInteger == false)
    }

    @Test(arguments: NodeKind.allCases)
    func parameterIDsAreUniqueAndDefaultsAreValid(kind: NodeKind) {
        let parameters = NodeCatalog.definition(for: kind).parameters
        #expect(Set(parameters.map(\.id)).count == parameters.count)
        for parameter in parameters {
            #expect(NodeCatalog.resolve(parameter.defaultValue, for: parameter) == parameter.defaultValue)
        }
    }

    @Test func v1PinLayout() {
        let audio = NodeCatalog.pins(of: Node(kind: .audio))
        #expect(audio == [PinDefinition(id: "out", direction: .output, signal: .audio, isRequired: false)])

        let print = NodeCatalog.pins(of: Node(kind: .print))
        #expect(print == [PinDefinition(id: "in", direction: .input, signal: .audio, isRequired: true)])

        // The LFO's optional Reset input arrived with the Clock (2026-10-15).
        let lfo = NodeCatalog.pins(of: Node(kind: .lfo))
        #expect(lfo == [
            PinDefinition(id: "reset", direction: .input, signal: .control, isRequired: false),
            PinDefinition(id: "out", direction: .output, signal: .control, isRequired: false),
        ])
    }

    @Test func outputSignalsIncludeRepeatedOutputs() {
        #expect(NodeCatalog.outputSignal("out", of: .lfo) == .control)
        #expect(NodeCatalog.outputSignal("out", of: .filters) == .audio)
        #expect(NodeCatalog.outputSignal("confidence", of: .pitchFollower) == .control)
        // Repeated outputs, at any number, even beyond today's count.
        #expect(NodeCatalog.outputSignal("out3", of: .channelSplitter) == .audio)
        #expect(NodeCatalog.outputSignal("out8", of: .channelSplitter) == .audio)
        // Inputs and unknown pins are not outputs.
        #expect(NodeCatalog.outputSignal("in1", of: .mixer) == nil)
        #expect(NodeCatalog.outputSignal("in", of: .filters) == nil)
        #expect(NodeCatalog.outputSignal("nope", of: .lfo) == nil)
        #expect(NodeCatalog.outputSignals(of: .channelSplitter) == [.audio])
        #expect(NodeCatalog.outputSignals(of: .print).isEmpty)
    }

    @Test func fractalFilterHasTheAgreedCatalogDefinition() throws {
        let definition = NodeCatalog.definition(for: .fractalFilter)
        #expect(definition.pins == [
            PinDefinition(id: "in", direction: .input, signal: .audio, isRequired: true),
            PinDefinition(id: "out", direction: .output, signal: .audio, isRequired: false),
        ])
        #expect(definition.lengthRule == .sameAsInput("in"))
        #expect(definition.parameters.map(\.id) == [
            "iterations", "warp", "bias", "q", "mix", "pattern", "phaseMode", "fftSize", "seed",
        ])
        #expect(definition.parameters.filter(\.isModulatable).map(\.id) == ["iterations", "warp", "bias", "q", "mix", "pattern", "phaseMode"])
        #expect(definition.parameter("iterations")?.isInteger == true)

        #expect(definition.parameter("warp")?.defaultValue == .number(1))
        #expect(definition.parameter("bias")?.defaultValue == .number(0))
        #expect(definition.parameter("q")?.defaultValue == .number(1))
        #expect(definition.parameter("mix")?.defaultValue == .number(1))
        #expect(definition.parameter("pattern")?.defaultValue == .choice("cantor"))
        #expect(definition.parameter("phaseMode")?.defaultValue == .choice("preserved"))
        #expect(definition.parameter("fftSize")?.defaultValue == .choice("4096"))
        #expect(definition.parameter("seed")?.defaultValue == .number(1))
        #expect(NodeKind.fractalFilter.category == .spectral)
    }

    @Test func wavetableNodesHaveExactCatalogDefinitions() throws {
        let single = NodeCatalog.definition(for: .singleCycle)
        #expect(single.pins == [PinDefinition(id: "out", direction: .output, signal: .audio, isRequired: false, channels: .mono)])
        #expect(single.lengthRule == .byChoice("mode", rules: ["oscillator": .seconds("length")], otherwise: .generated(frameSize: "frameSize", count: "cycles")))
        #expect(single.parameter("frameSize")?.defaultValue == .choice("2048"))
        #expect(single.parameter("cycles")?.defaultValue == .number(1))
        #expect(single.parameter("seed")?.defaultValue == .number(1))
        #expect(NodeCatalog.definition(for: .wavetableFactory).lengthRule == .generated(frameSize: "frameSize", count: "slots"))
        #expect(NodeCatalog.definition(for: .wavetableFactory).repeated == [RepeatedPins(prefix: "in", direction: .input, signal: .audio, count: .growing("inputCount", minimum: 2, maximum: 16))])
        #expect(NodeCatalog.definition(for: .wavetableFactory).needsAnyInput)
        #expect(NodeCatalog.definition(for: .wavetableFactory).parameters.allSatisfy { !$0.isModulatable })
    }

    @Test func wavetableFramesAreABakeOnlySettingAndOffByDefault() throws {
        let bake = NodeCatalog.definition(for: .print)
        let wavetable = try #require(bake.parameter("wavetable"))
        #expect(wavetable.kind == .choice(options: ["off", "256", "512", "1024", "2048", "4096"], defaultValue: "off"))
        #expect(wavetable.role == .setting && !wavetable.isModulatable)
        #expect(NodeCatalog.definition(for: .preview).parameter("wavetable") == nil)
        let defaults = NodeCatalog.defaultParameters(for: .print)
        #expect(defaults["wavetable"] == .choice("off"))
    }

    @Test func previewIsAnOutputWithOneAudioInput() {
        #expect(NodeKind.preview.isOutput && NodeKind.print.isOutput && !NodeKind.filters.isOutput)
        #expect(NodeCatalog.pins(of: Node(kind: .preview)) == [PinDefinition(id: "in", direction: .input, signal: .audio, isRequired: true)])
    }

    @Test func theBakeFileNameIsOnTheFrontOfTheCard() throws {
        // Stored as `prefix` since v1; only the label and page changed.
        let name = try #require(NodeCatalog.definition(for: .print).parameter("prefix"))
        #expect(name.name == "File Name")
        #expect(name.role == .macro)
    }

    @Test func tickingAParameterSpawnsAControlPin() {
        let pins = NodeCatalog.pins(of: Node(kind: .filters, modulated: ["cutoff"]))
        #expect(pins.contains(PinDefinition(id: "mod.cutoff", direction: .input, signal: .control, isRequired: false)))
    }

    @Test func nonModulatableParametersNeverSpawnPins() {
        let pins = NodeCatalog.pins(of: Node(kind: .stretch, modulated: ["ratio"]))
        #expect(!pins.contains { $0.id == "mod.ratio" })
    }

    @Test func resolveFillsDefaultsAndClamps() {
        let resolved = NodeCatalog.resolvedParameters(of: Node(kind: .filters, parameters: ["cutoff": .number(99_999)]))
        #expect(resolved["cutoff"] == .number(20_000))
        #expect(resolved["type"] == .choice("lowpass"))
        #expect(resolved["q"] == .number(0.707))
    }

    @Test func resolveRejectsWrongTypesAndUnknownChoices() throws {
        let filters = NodeCatalog.definition(for: .filters)
        let type = try #require(filters.parameter("type"))
        let cutoff = try #require(filters.parameter("cutoff"))
        #expect(NodeCatalog.resolve(.choice("banana"), for: type) == nil)
        #expect(NodeCatalog.resolve(.text("loud"), for: cutoff) == nil)
        #expect(NodeCatalog.resolve(.number(.nan), for: cutoff) == nil)
    }

    @Test func frequenciesModulateInOctaves() throws {
        #expect(try #require(NodeCatalog.definition(for: .filters).parameter("cutoff")).modulationScale == .exponential)
        #expect(try #require(NodeCatalog.definition(for: .lfo).parameter("rate")).modulationScale == .exponential)
        #expect(try #require(NodeCatalog.definition(for: .filters).parameter("q")).modulationScale == .linear)
    }

    @Test(arguments: NodeKind.allCases)
    func exponentialRangesStayPositive(kind: NodeKind) {
        for parameter in NodeCatalog.definition(for: kind).parameters where parameter.modulationScale == .exponential {
            if case .number(let range, _, _) = parameter.kind {
                #expect(range.lowerBound > 0, "\(kind).\(parameter.id)")
            }
        }
    }

    @Test func resonatorIsAnAudioEffectWithStaticBandCount() throws {
        let definition = NodeCatalog.definition(for: .resonator)
        #expect(definition.pins.map(\.id) == ["in", "out"])
        #expect(definition.lengthRule == .sameAsInput("in"))
        let bands = try #require(definition.parameter("bands"))
        #expect(bands.role == .setting)
        #expect(bands.defaultValue == .number(64))
        // The GPU retunes every 64 frames while these are modulated; the band count stays fixed.
        #expect(Set(definition.parameters.filter(\.isModulatable).map(\.id)) == ["root", "fine", "decay", "inharmonicity", "mix"])
        #expect(!bands.isModulatable)
    }

    @Test func controlPinsAreNamedOnCards() {
        #expect(NodeCatalog.label(of: "reset", on: Node(kind: .lfo)) == "Reset")
        #expect(NodeCatalog.label(of: "trigger", on: Node(kind: .envelope)) == "Trigger")
        #expect(NodeCatalog.label(of: "a", on: Node(kind: .math)) == "A")
        #expect(NodeCatalog.label(of: "in", on: Node(kind: .filters)) == "In")
        #expect(NodeCatalog.label(of: "out", on: Node(kind: .clock)) == "Out")
    }

    @Test func singleCycleAndFactoryCatalogParametersAreStable() {
        #expect(NodeCatalog.definition(for: .singleCycle).parameters.count == 13)
        // 10 settings, plus Source (first 1,024 cycles for old patches, or the whole input).
        #expect(NodeCatalog.definition(for: .wavetableFactory).parameters.count == 11)
        #expect(NodeCatalog.definition(for: .singleCycle).parameter("seed")?.isModulatable == false)
        #expect(NodeCatalog.definition(for: .wavetableFactory).parameters.allSatisfy { !$0.isModulatable })
    }

    @Test func theLFOCanSyncToAClock() throws {
        let definition = NodeCatalog.definition(for: .lfo)
        let sync = try #require(definition.parameter("sync"))
        #expect(sync.defaultValue == .choice("free") && sync.role == .setting)
        #expect(sync.kind == .choice(options: ["free", "clock", "overLength"], defaultValue: "free"))
        let cycles = try #require(definition.parameter("cyclesPerBang"))
        #expect(cycles.kind == .choice(options: ["1/4", "1/2", "1", "2", "3", "4", "8"], defaultValue: "1"))
        #expect(cycles.role == .setting)
    }

    @Test func theLFOHasAnOptionalResetInput() {
        let pins = NodeCatalog.definition(for: .lfo).pins
        #expect(pins.map(\.id) == ["reset", "out"])
        #expect(pins[0].direction == .input && pins[0].signal == .control && !pins[0].isRequired)
    }

    @Test func batchNodesHaveTheirPinsAndControls() {
        let audio = NodeCatalog.definition(for: .batchAudio)
        #expect(audio.pins.map(\.id) == ["out"])
        #expect(audio.parameters.map(\.id) == ["gain", "formats", "order", "seed", "interpolation"])
        #expect(audio.lengthRule == .asset)
        let bake = NodeCatalog.definition(for: .batchBake)
        #expect(bake.pins.map(\.id) == ["in"])
        #expect(bake.parameters.map(\.id) == ["naming", "name", "digits", "seed", "bitDepth", "versions", "cleanUp", "noiseFloor", "fade", "dcRemoval", "normalize", "targetPeak"])
        #expect(NodeCatalog.definition(for: .print).parameters.suffix(6).map(\.id) == ["cleanUp", "noiseFloor", "fade", "dcRemoval", "normalize", "targetPeak"])
        #expect(NodeCatalog.defaultParameters(for: .print)["cleanUp"] == .choice("off"))
        #expect(NodeCatalog.defaultParameters(for: .batchBake)["name"] == .text("{source}"))
        #expect(NodeKind.batchBake.isOutput && NodeKind.batchAudio.isBatch && NodeKind.batchBake.isBatch)
        #expect(!NodeKind.audio.isBatch && !NodeKind.print.isBatch && !NodeKind.batchAudio.isOutput)
    }

    @Test func aBatchAudioFolderRoundTripsAndBatchNodesCantBeGrouped() throws {
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let gain = project.addNode(.gainVCA, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.setSourceFolder(FileReference(lastKnownPath: "/Drums"), for: source)
        project.setOutputFolder(FileReference(lastKnownPath: "/Out"), for: bake)
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(project))
        #expect(decoded.node(source)?.sourceFolder?.lastKnownPath == "/Drums")
        #expect(decoded.node(bake)?.outputFolder?.lastKnownPath == "/Out")
        #expect(project.canGroup([gain]))
        #expect(!project.canGroup([source, gain]))
        #expect(!project.canGroup([gain, bake]))
    }

    @Test func largeAudioProcessorHasItsControls() {
        let definition = NodeCatalog.definition(for: .largeAudio)
        #expect(definition.pins.map(\.id) == ["out"])
        #expect(definition.parameters.map(\.id) == [
            "gain", "sliceMode", "threshold", "sensitivity", "bpm", "bars", "every", "minLength", "maxLength", "fade",
            "backTrack", "jitter", "seed", "interpolation",
        ])
        #expect(definition.lengthRule == .asset)
        #expect(NodeKind.largeAudio.isBatch && NodeKind.largeAudio.isBatchSource && !NodeKind.batchBake.isBatchSource)
        var project = ProjectFile()
        let node = project.addNode(.largeAudio, at: CanvasPoint())
        #expect(project.assignAudio(path: "/long.wav", bookmark: nil, to: node) != nil)
        #expect(!project.canGroup([node]))
    }

    @Test func concatenateIsAGatherWithItsSettings() {
        let definition = NodeCatalog.definition(for: .concatenate)
        #expect(definition.pins.map(\.id) == ["out"])
        #expect(definition.repeated.first?.prefix == "in")
        #expect(NodeCatalog.pins(of: Node(kind: .concatenate)).map(\.id) == ["out", "in1", "in2"])
        #expect(definition.parameters.map(\.id) == ["gap", "crossfade", "order", "seed", "inputCount"])
        #expect(definition.parameters.allSatisfy { !$0.isModulatable })
        #expect(NodeKind.concatenate.isGather && NodeKind.concatenate.isBatch && !NodeKind.concatenate.isBatchSource)
        #expect(NodeKind.concatenate.category == .batch && NodeKind.batchAudio.category == .batch)
    }
}
