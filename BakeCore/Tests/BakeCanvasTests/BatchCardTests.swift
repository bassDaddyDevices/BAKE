import BakeGraph
import Testing
@testable import BakeCanvas

struct BatchCardTests {
    @Test func theFolderRowSaysHowManyFilesItPlays() {
        #expect(BatchFolderRow.countText(nil) == "Folder not found")
        #expect(BatchFolderRow.countText(0) == "No audio files")
        #expect(BatchFolderRow.countText(1) == "1 file")
        #expect(BatchFolderRow.countText(48) == "48 files")
    }

    @Test func theBatchBakeButtonSaysHowManyFilesItWrites() {
        #expect(MacroPage.bakeFilesTitle(1) == "Bake 1 File")
        #expect(MacroPage.bakeFilesTitle(48) == "Bake 48 Files")
    }
}

struct SliceCardTests {
    @Test func theSlicerSaysHowManySlicesItMade() {
        #expect(MacroPage.sliceCountText(nil) == "Slicing…")
        #expect(MacroPage.sliceCountText(0) == "No slices")
        #expect(MacroPage.sliceCountText(1) == "1 slice")
        #expect(MacroPage.sliceCountText(38) == "38 slices")
    }
}

struct ConcatenateCardTests {
    @Test func theCardSaysHowManyClipsItJoins() {
        #expect(MacroPage.gatherText(.concatenate, 0) == "Joins every file of the batch before it")
        #expect(MacroPage.gatherText(.concatenate, 1) == "Joins 1 clip")
        #expect(MacroPage.gatherText(.concatenate, 48) == "Joins 48 clips")
        #expect(MacroPage.gatherText(.corpusScatter, 5) == "Gathers 5 clips")
        #expect(MacroPage.gatherText(.ensembleAverager, 1) == "Gathers 1 clip")
        // Several inputs: without a batch, and in one.
        #expect(MacroPage.gatherText(.concatenate, nil, inputs: 3) == "Joins 3 inputs end to end")
        #expect(MacroPage.gatherText(.concatenate, nil, inputs: 0) == "Joins its inputs end to end")
        #expect(MacroPage.gatherText(.concatenate, 12, inputs: 2) == "Joins 2 inputs × 12 files = 24 clips")
        #expect(MacroPage.gatherText(.concatenate, 12, inputs: 1) == "Joins 12 clips")
    }
}

struct ScatterCardTests {
    @Test func theOnsetDotsAreTheScheduleOfTheFirstSeconds() {
        let values = NodeCatalog.resolvedParameters(of: Node(id: NodeID(), kind: .corpusScatter, parameters: [
            "distribution": .choice("uniform"), "density": .number(4), "duration": .number(60),
        ]))
        let grains = ScatterOnsets.grains(values, clips: 3)
        #expect(grains.map(\.start) == (0..<16).map { $0 * 250 })
        #expect(ScatterOnsets.grains(values, clips: 0).count == 16)  // before the folder is chosen
    }
}

struct MatrixCardTests {
    @Test func theCardSaysHowManyCombinationsItMakes() {
        #expect(MacroPage.combinationsText([10, 10, 10]) == "10 × 10 × 10 = 1000 combinations")
        #expect(MacroPage.combinationsText([2, 3, 1]) == "2 × 3 × 1 = 6 combinations")
        #expect(MacroPage.combinationsText([1, 1, 1]) == "1 × 1 × 1 = 1 combination")
        #expect(MacroPage.combinationsText([]) == "Layers A, B and C. Feed batches in for every combination.")
    }
}

struct RouterCardTests {
    private func values(_ kind: NodeKind, _ parameters: [ParameterID: ParameterValue]) -> [ParameterID: ParameterValue] {
        NodeCatalog.resolvedParameters(of: Node(id: NodeID(), kind: kind, parameters: parameters))
    }

    @Test func theSplitterShowsWhereTheFirstPassesGo() {
        let robin = values(.forEachSplitter, ["mode": .choice("roundRobin"), "outputs": .choice("3")])
        #expect(MacroPage.splitterText(robin, passes: 7) == "1 → out 1 · 2 → out 2 · 3 → out 3 · 4 → out 1 · …")
        #expect(MacroPage.splitterText(robin, passes: 2) == "1 → out 1 · 2 → out 2")
        #expect(MacroPage.splitterText(robin, passes: 0) == "Sends each file of the batch before it down one output.")
        #expect(MacroPage.splitterText(values(.forEachSplitter, ["mode": .choice("broadcast")]), passes: 3) == "Every file goes down every output.")
    }

    @Test func theSorterShowsItsRangesInItsMeasuresUnits() {
        #expect(MacroPage.sorterText(values(.spectralSorter, [:])) == "Low < 150 Hz · Mid 150–3000 Hz · High ≥ 3000 Hz")
        #expect(MacroPage.sorterText(values(.spectralSorter, ["measure": .choice("loudness")])) == "Low < -30 dBFS · Mid -30–-12 dBFS · High ≥ -12 dBFS")
        #expect(MacroPage.sorterText(values(.spectralSorter, ["measure": .choice("decay"), "decayLow": .number(50)])) == "Low < 50 ms · Mid 50–500 ms · High ≥ 500 ms")
    }
}

struct MerryGoRoundCardTests {
    @Test func theCardShowsTheFirstSixDeals() {
        let values = NodeCatalog.resolvedParameters(of: Node(id: NodeID(), kind: .merryGoRound, parameters: ["order": .choice("pingPong")]))
        #expect(MacroPage.dealText(values, passes: 9) == "1 → out 1 · 2 → out 2 · 3 → out 3 · 4 → out 2 · 5 → out 1 · 6 → out 2 · …")
        #expect(MacroPage.dealText(values, passes: 2) == "1 → out 1 · 2 → out 2")
        #expect(MacroPage.dealText(values, passes: 0) == "Deals each file of the batch before it to one output in turn.")
    }
}

struct PhotoBoothCardTests {
    private func booth(_ parameters: [ParameterID: ParameterValue] = [:]) -> [ParameterID: ParameterValue] {
        NodeCatalog.resolvedParameters(of: Node(kind: .photoBooth, parameters: parameters))
    }

    @Test func theCardCountsGridChunksOrWaitsForTheTrigger() {
        #expect(MacroPage.boothText(booth(), count: 16) == "16 chunks, every 1/4 at 120 BPM")
        #expect(MacroPage.boothText(booth(["every": .choice("ms"), "everyMs": .number(500)]), count: 1) == "1 chunk, every 500 ms")
        #expect(MacroPage.boothText(booth(), count: nil) == "A chunk at each trigger.")
        #expect(MacroPage.bakeFilesTitle(nil) == "Bake Files")
    }

    @Test func onlyABoothOnItsOwnGridIsCountedBeforeABake() throws {
        var project = ProjectFile()
        let grid = project.addNode(.photoBooth, at: CanvasPoint())
        let wired = project.addNode(.photoBooth, at: CanvasPoint())
        let clock = project.addNode(.clock, at: CanvasPoint())
        try project.connect(from: PinRef(node: clock, pin: "out"), to: PinRef(node: wired, pin: "trigger"))
        let shape = SignalShape(frames: 4 * 48_000, channels: 2)
        let counts = WorkspaceView.boothCounts(in: project, lengths: [grid: shape, wired: shape])
        #expect(counts == [grid: 8])
    }
}

struct ConformCardTests {
    private func conform(_ parameters: [ParameterID: ParameterValue] = [:]) -> [ParameterID: ParameterValue] {
        NodeCatalog.resolvedParameters(of: Node(kind: .batchConform, parameters: parameters))
    }

    @Test func theCardSaysWhereEveryFileGoes() {
        #expect(MacroPage.conformText(conform()) == "Every file → 120 BPM, C")
        #expect(MacroPage.conformText(conform(["conform": .choice("tempo"), "targetBPM": .number(87.5)])) == "Every file → 87.5 BPM")
        #expect(MacroPage.conformText(conform(["conform": .choice("key"), "targetKey": .choice("F#")])) == "Every file → F#")
    }
}

struct ChoiceTitleTests {
    @Test func camelCaseIdsReadAsWords() {
        #expect(ParameterFormat.title(forChoice: "trueStereo", of: "stereo") == "True Stereo")
        #expect(ParameterFormat.title(forChoice: "spectralFlux", of: "mode") == "Spectral Flux")
        #expect(ParameterFormat.title(forChoice: "zeroCrossing", of: "feature") == "Zero Crossing")
        #expect(ParameterFormat.title(forChoice: "trackAndHold", of: "mode") == "Track & Hold")
        #expect(ParameterFormat.title(forChoice: "rms", of: "detector") == "RMS")
        #expect(ParameterFormat.title(forChoice: "matrix", of: "stereo") == "Matrix")
    }
}
