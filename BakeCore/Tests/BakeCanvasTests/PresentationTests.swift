import BakeGraph
import Foundation
import Testing
@testable import BakeCanvas

struct PresentationTests {
    private let english = Locale(identifier: "en_US")

    @Test func valuesFormatWithTheirUnits() {
        #expect(ParameterFormat.string(440, unit: "Hz", locale: english) == "440 Hz")
        #expect(ParameterFormat.string(1_000, unit: "Hz", locale: english) == "1 kHz")
        #expect(ParameterFormat.string(1_234.5, unit: "Hz", locale: english) == "1.23 kHz")
        #expect(ParameterFormat.string(0.707, unit: "", locale: english) == "0.71")
        #expect(ParameterFormat.string(-3, unit: "st", locale: english) == "-3 st")
        #expect(ParameterFormat.string(2.5, unit: "×", locale: english) == "2.5×")
        #expect(ParameterFormat.string(90, unit: "°", locale: english) == "90°")
    }

    @Test func choicesGetReadableTitles() {
        #expect(ParameterFormat.title(forChoice: "lowpass", of: "type") == "Low-pass")
        #expect(ParameterFormat.title(forChoice: "24", of: "slope") == "24 dB/oct")
        #expect(ParameterFormat.title(forChoice: "24", of: "bitDepth") == "24-bit")
        #expect(ParameterFormat.title(forChoice: "32f", of: "bitDepth") == "32-bit float")
        #expect(ParameterFormat.title(forChoice: "8", of: "oversampling") == "8×")
        #expect(ParameterFormat.title(forChoice: "sampleAndHold", of: "shape") == "Sample & Hold")
        #expect(ParameterFormat.title(forChoice: "cantor", of: "pattern") == "Cantor Set")
        #expect(ParameterFormat.title(forChoice: "mandelbrot", of: "pattern") == "Mandelbrot")
        #expect(ParameterFormat.title(forChoice: "julia", of: "pattern") == "Julia")
        #expect(ParameterFormat.title(forChoice: "koch", of: "pattern") == "Koch Snowflake")
        #expect(ParameterFormat.title(forChoice: "randomized", of: "phaseMode") == "Phase Randomize")
    }

    @Test func halfTimeSpeedGivesTheTopOfItsRangeMoreTravel() throws {
        let speed = try #require(NodeCatalog.definition(for: .halfTime).parameter("speed"))
        guard case .number(let range, _, _) = speed.kind else { Issue.record("Speed is a number"); return }
        let mapping = SliderMapping(range: range, scale: speed.modulationScale, taper: speed.taper)
        let half = mapping.position(for: 0.5), sixteenth = mapping.position(for: 1.0 / 16)
        #expect(abs(half - 0.707) < 0.01)            // 1× to 0.5× is the top 29 % of the slider
        #expect(abs(sixteenth - 0.25) < 0.01)
        #expect(abs(mapping.value(at: half) - 0.5) < 1e-9)
        #expect(mapping.value(at: 0) == range.lowerBound && mapping.value(at: 1) == range.upperBound)
    }

    @Test func linearSlidersMapProportionally() {
        let mapping = SliderMapping(range: 0...10, scale: .linear)
        #expect(mapping.position(for: 5) == 0.5)
        #expect(mapping.value(at: 0.25) == 2.5)
        #expect(mapping.position(for: 20) == 1)
    }

    @Test func frequencySlidersMoveInOctaves() {
        let mapping = SliderMapping(range: 20...20_000, scale: .exponential)
        #expect(abs(mapping.value(at: 0.5) - (20 * 20_000).squareRoot()) < 1e-6)
        #expect(abs(mapping.value(at: mapping.position(for: 1_000)) - 1_000) < 1e-6)
    }

    @Test func durationsReadNaturally() {
        #expect(ParameterFormat.duration(4) == "4.0 s")
        #expect(ParameterFormat.duration(42) == "42 s")
        #expect(ParameterFormat.duration(1_000) == "16 min 40 s")
        #expect(ParameterFormat.duration(3_900) == "1 h 5 min")
        // Under a second in milliseconds: a 2048-frame wavetable cycle at 48 kHz.
        #expect(ParameterFormat.duration(2_048.0 / 48_000) == "43 ms")
        #expect(ParameterFormat.duration(0.5) == "500 ms")
    }

    @Test func shortModulationSourcesAndVeryLongAudioAreFlagged() {
        #expect(OutputLengthRow.warning(seconds: 0.043, isModulationSource: true) == .shortModulation)
        #expect(OutputLengthRow.warning(seconds: 0.043, isModulationSource: false) == nil)
        #expect(OutputLengthRow.warning(seconds: 2, isModulationSource: true) == nil)
        #expect(OutputLengthRow.warning(seconds: 600, isModulationSource: false) == .long)
        #expect(OutputLengthRow.warning(seconds: 600, isModulationSource: true) == .long)
    }

    @Test func lfoPictureShowsEveryCycleOverLength() {
        #expect(LFOShapeView(shape: "sine", depth: 1, phase: 0, seed: 0, rate: 1).shownCycles == 2)
        #expect(LFOShapeView(shape: "sine", depth: 1, phase: 0, seed: 0, rate: 1, overLength: true, cycles: 8).shownCycles == 8)
    }

    @Test func wideRangesMoveLogarithmically() {
        // Stretch Ratio 0.1–1000×: 1× sits a quarter of the way along, not at the far left.
        let ratio = SliderMapping(range: 0.1...1_000, scale: .linear)
        #expect(abs(ratio.position(for: 1) - 0.25) < 1e-9)
        // Ranges under 100× stay linear.
        let bands = SliderMapping(range: 64...1_024, scale: .linear)
        #expect(bands.position(for: 544) == 0.5)
    }

    @Test func exponentialMappingFallsBackToLinearForNonPositiveRanges() {
        let mapping = SliderMapping(range: 0...1, scale: .exponential)
        #expect(mapping.value(at: 0.5) == 0.5)
    }

    @MainActor @Test func macroCardUsesItsLabelValueAndWidget() {
        let view = MacroControlView(value: 0.5, label: "Character", widget: "slider")
        #expect(view.value == 0.5)
        #expect(view.label == "Character")
        #expect(view.widget == "slider")
    }

    @Test func everyKindHasATitle() {
        #expect(NodeKind.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(NodeKind.lfo.title == "LFO")
        #expect(NodeKind.macro.title == "Macro")
        // Stored as `print` since v1; shown as Bake.
        #expect(NodeKind.print.title == "Bake")
        #expect(NodeKind.preview.title == "Preview")
        #expect(NodeKind.singleCycle.title == "Single Cycle")
        #expect(NodeKind.wavetableFactory.title == "Wavetable Factory")
        #expect(NodeKind.fractalFilter.title == "Fractal Filter")
    }

    @Test func bakeCardsNameTheirFolder() {
        var project = ProjectFile()
        let bake = project.addNode(.print, at: CanvasPoint())
        #expect(WorkspaceView.folderName(for: project.nodes[0], in: project) == nil)
        project.settings.printFolder = FileReference(lastKnownPath: "/Users/me/Bounces")
        #expect(WorkspaceView.folderName(for: project.nodes[0], in: project) == "Default: Bounces")
        project.setOutputFolder(FileReference(lastKnownPath: "/Users/me/Drums"), for: bake)
        #expect(WorkspaceView.folderName(for: project.nodes[0], in: project) == "Drums")
    }

    @Test func waveformsResampleToTheBarsThatFit() {
        let peaks = WaveformPeaks(peaks: [0.1, 0.9, 0.2, 0.4])
        #expect(WaveformView.bars(for: peaks, count: 2) == [0.9, 0.4])   // loudest of each half
        #expect(WaveformView.bars(for: peaks, count: 8).count == 4)      // never invent detail
        #expect(WaveformView.bars(for: WaveformPeaks(peaks: []), count: 8).isEmpty)
    }

    @Test func bakeVersionChoicesReadNaturally() {
        #expect(ParameterFormat.title(forChoice: "newVersion", of: "versions") == "Save a New Version")
        #expect(ParameterFormat.title(forChoice: "overwrite", of: "versions") == "Replace It")
    }

    /// Owner request: modulation cards wear the control-wire colour instead of the accent.
    @Test func modulationSourcesAreTheNodesThatOnlyOutputControl() {
        let sources = Set(NodeKind.allCases.filter(\.isModulationSource))
        #expect(sources == [.lfo, .random, .sampleAndHold, .envelope, .envelopeFollower, .pitchFollower, .transientDetector, .featureFollower, .math, .logic, .quantizer, .clock, .macro])
        #expect(NodeKind.lfo.cardColor == SignalType.control.color)
        #expect(NodeKind.filters.cardColor == .accentColor)
    }

    /// "Linear (FIR)" is the Filters' phase; everywhere else "linear" is just Linear.
    @Test func linearMeansFIROnlyOnTheFiltersPhase() {
        #expect(ParameterFormat.title(forChoice: "linear", of: "phase") == "Linear (FIR)")
        #expect(ParameterFormat.title(forChoice: "minimum", of: "phase") == "Minimum (IIR)")
        for parameter: ParameterID in ["curve", "mode", "interpolation", "spacing"] {
            #expect(ParameterFormat.title(forChoice: "linear", of: parameter) == "Linear", "\(parameter)")
        }
    }

    @Test func envelopeModesReadNaturally() {
        #expect(ParameterFormat.title(forChoice: "oneShot", of: "triggerMode") == "One-shot")
        #expect(ParameterFormat.title(forChoice: "gate", of: "triggerMode") == "Gate")
        #expect(ParameterFormat.title(forChoice: "classic", of: "triggerMode") == "Classic")
    }

    @Test func addNodeGroupsHaveTitles() {
        #expect(NodeCategory.allCases.map(\.title) == ["In & Out", "Batch", "Effects", "Time", "Spectral", "Wavetable", "Routing", "Modulation", "Custom"])
    }

    @Test func clockDivisionsReadAsMusic() {
        #expect(ParameterFormat.title(forChoice: "1/4", of: "division") == "1/4")
        #expect(ParameterFormat.title(forChoice: "1/8d", of: "division") == "1/8 dotted")
        #expect(ParameterFormat.title(forChoice: "1/16t", of: "division") == "1/16 triplet")
        #expect(NodeKind.clock.title == "Clock")
    }
}

struct TypedValueTests {
    @Test func typedTextReadsAsANumber() {
        #expect(TypedValue.number(in: "140.5") == 140.5)
        #expect(TypedValue.number(in: "140,5") == 140.5)
        #expect(TypedValue.number(in: "500 ms") == 500)
        #expect(TypedValue.number(in: "-3 st") == -3)
        #expect(TypedValue.number(in: "2k") == 2_000)
        #expect(TypedValue.number(in: "1.5 kHz") == 1_500)
        #expect(TypedValue.number(in: ".25") == 0.25)
        #expect(TypedValue.number(in: "fast") == nil)
    }
}
