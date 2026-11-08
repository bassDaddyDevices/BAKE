import Testing
@testable import BakeGraph

/// For Each Splitter and Spectral Sorter in a batch: each pass goes down some outputs, and what's behind
/// the others sits it out.
struct RouterBatchRunTests {
    private struct Patch {
        var project = ProjectFile()
        let source: NodeID, router: NodeID, bakes: [NodeID]
    }

    /// Batch Audio → `kind` (with `parameters`) → one Filters → Batch Bake per output pin.
    private func patch(_ kind: NodeKind, _ parameters: [ParameterID: ParameterValue] = [:], naming: [ParameterID: ParameterValue] = [:]) throws -> Patch {
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let router = project.addNode(kind, at: CanvasPoint())
        project.setSourceFolder(FileReference(lastKnownPath: "/drums"), for: source)
        for (id, value) in parameters { project.setParameter(id, of: router, to: value) }
        try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: router, pin: "in"))
        var bakes: [NodeID] = []
        let node = try #require(project.node(router))
        for pin in NodeCatalog.pins(of: node) where pin.direction == .output {
            let filters = project.addNode(.filters, at: CanvasPoint())
            let bake = project.addNode(.batchBake, at: CanvasPoint())
            for (id, value) in naming { project.setParameter(id, of: bake, to: value) }
            try project.connect(from: PinRef(node: router, pin: pin.id), to: PinRef(node: filters, pin: "in"))
            try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: bake, pin: "in"))
            bakes.append(bake)
        }
        return Patch(project: project, source: source, router: router, bakes: bakes)
    }

    private let files = (1...7).map { BatchFile(path: "/drums/hit\($0).wav") }

    /// For each pass, the indices of the Batch Bakes that write.
    private func writers(_ patch: Patch, passes: Int? = nil, routes: (Int) -> BatchRun.Routes = { _ in [:] }) -> [[Int]] {
        let run = BatchRun(project: patch.project, files: [patch.source: files])
        return (0..<(passes ?? run.passCount)).map { index in
            guard let pass = run.batchPass(index, routes: routes(index)) else { return [] }
            return patch.bakes.indices.filter { pass.node(patch.bakes[$0]) != nil }
        }
    }

    @Test func eachModeSendsThePassesWhereItSays() throws {
        let robin = try patch(.forEachSplitter, ["mode": .choice("roundRobin"), "outputs": .choice("3")])
        #expect(writers(robin) == [[0], [1], [2], [0], [1], [2], [0]])  // 3 + 2 + 2 files
        let oddEven = try patch(.forEachSplitter, ["mode": .choice("oddEven")])
        #expect(writers(oddEven) == [[0], [1], [0], [1], [0], [1], [0]])
        let blocks = try patch(.forEachSplitter, ["mode": .choice("blocks"), "outputs": .choice("3")])
        #expect(writers(blocks) == [[0], [0], [0], [1], [1], [1], [2]])  // blocks of ⌈7 / 3⌉
        let broadcast = try patch(.forEachSplitter, ["mode": .choice("broadcast"), "outputs": .choice("3")])
        #expect(writers(broadcast).allSatisfy { $0 == [0, 1, 2] })
    }

    @Test func whatSitsAPassOutIsLeftOutEntirely() throws {
        let robin = try patch(.forEachSplitter, ["mode": .choice("roundRobin")])
        let run = BatchRun(project: robin.project, files: [robin.source: files])
        let pass = try #require(run.batchPass(1))
        // Only the second branch's Filters and Bake are left behind the splitter.
        #expect(pass.edges.allSatisfy { $0.from != PinRef(node: robin.router, pin: "out1") })
        #expect(pass.nodes.filter { $0.kind == .filters }.count == 1)
        // A single render (cards, Preview) has every branch on.
        #expect(run.pass(1).nodes.filter { $0.kind == .filters }.count == 2)
    }

    @Test func numbersCountEachBatchBakesOwnFiles() throws {
        let robin = try patch(.forEachSplitter, ["mode": .choice("roundRobin")], naming: ["naming": .choice("numbered"), "name": .text("hit")])
        let run = BatchRun(project: robin.project, files: [robin.source: files])
        #expect([0, 2, 4, 6].map { run.fileName(of: robin.bakes[0], pass: $0) } == ["hit_001", "hit_002", "hit_003", "hit_004"])
        #expect([1, 3, 5].map { run.fileName(of: robin.bakes[1], pass: $0) } == ["hit_001", "hit_002", "hit_003"])
        // A sorter's bake is numbered by what the session counts.
        #expect(run.fileName(of: robin.bakes[0], pass: 6, ordinal: 9) == "hit_010")
    }

    @Test func aSorterSendsEachPassWhereItsMeasureSaid() throws {
        let sorter = try patch(.spectralSorter)
        // Before it's measured, every branch is on; after, only the route (or none, when dropped).
        #expect(writers(sorter).allSatisfy { $0 == [0, 1, 2] })
        let routes: [PinID?] = ["low", "high", nil, "mid", "low", "low", "high"]
        let routed = writers(sorter) { [sorter.router: routes[$0]] }
        #expect(routed == [[0], [2], [], [1], [0], [0], [2]])
    }

    @Test func theProbeCapturesOnlyWhatReachesTheSorter() throws {
        let sorter = try patch(.spectralSorter)
        let run = BatchRun(project: sorter.project, files: [sorter.source: files])
        #expect(run.sorters == [sorter.router])
        let probe = try #require(run.measureProbe(2))
        #expect(probe.nodes.filter(\.kind.isOutput).map(\.id) == [sorter.router])
        #expect(probe.node(sorter.router)?.parameters["prefix"] == .text(BatchRun.captureName(of: sorter.router, pass: 2)))
        #expect(!probe.edges.contains { $0.from.node == sorter.router })
        #expect(BatchRun(project: try patch(.forEachSplitter).project, files: [:]).measureProbe(0) == nil)
    }
}
