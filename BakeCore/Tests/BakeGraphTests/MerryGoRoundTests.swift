import Testing
@testable import BakeGraph

/// Merry-Go-Round's deal: which output each pass goes to.
struct MerryGoRoundTests {
    private func deal(_ parameters: [ParameterID: ParameterValue], passes: Int = 9) -> [Int] {
        let values = NodeCatalog.resolvedParameters(of: Node(id: NodeID(), kind: .merryGoRound, parameters: parameters))
        return BatchRun.merryGoRoundDeal(values, passes: passes).map { $0 + 1 }
    }

    @Test func forwardAndPingPongGoRoundAndBack() {
        #expect(deal([:]) == [1, 2, 3, 1, 2, 3, 1, 2, 3])
        #expect(deal(["order": .choice("pingPong")]) == [1, 2, 3, 2, 1, 2, 3, 2, 1])
        #expect(deal(["order": .choice("pingPong"), "outputs": .choice("2")], passes: 5) == [1, 2, 1, 2, 1])
    }

    @Test func randomNeverRepeatsAndIsTheSameForTheSameSeed() {
        let one = deal(["order": .choice("random"), "outputs": .choice("4"), "seed": .number(7)], passes: 500)
        #expect(zip(one.dropFirst(), one).allSatisfy { $0 != $1 })
        #expect(Set(one) == [1, 2, 3, 4])
        #expect(one == deal(["order": .choice("random"), "outputs": .choice("4"), "seed": .number(7)], passes: 500))
        #expect(one != deal(["order": .choice("random"), "outputs": .choice("4"), "seed": .number(8)], passes: 500))
    }

    @Test func aPatternRepeatsWrapsAndSkipsWhatIsntANumber() {
        #expect(deal(["order": .choice("pattern"), "pattern": .text("1 1 3 2")], passes: 8) == [1, 1, 3, 2, 1, 1, 3, 2])
        // 5 wraps to 2 of 3 outputs; "x" and 0 are skipped.
        #expect(deal(["order": .choice("pattern"), "pattern": .text("5, x 0 3")], passes: 4) == [2, 3, 2, 3])
        #expect(deal(["order": .choice("pattern"), "pattern": .text("none")], passes: 4) == [1, 2, 3, 1])
    }

    @Test func holdKeepsConsecutivePassesTogether() {
        #expect(deal(["hold": .number(3)]) == [1, 1, 1, 2, 2, 2, 3, 3, 3])
        let random = deal(["order": .choice("random"), "hold": .number(2)], passes: 40)
        #expect(stride(from: 0, to: 40, by: 2).allSatisfy { random[$0] == random[$0 + 1] })
    }

    @Test func eachBatchBakeWritesTheFilesDealtToIt() throws {
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let round = project.addNode(.merryGoRound, at: CanvasPoint())
        project.setSourceFolder(FileReference(lastKnownPath: "/hits"), for: source)
        project.setParameter("order", of: round, to: .choice("pingPong"))
        try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: round, pin: "in"))
        var bakes: [NodeID] = []
        for pin in ["out1", "out2", "out3"] {
            let bake = project.addNode(.batchBake, at: CanvasPoint())
            project.setParameter("naming", of: bake, to: .choice("numbered"))
            project.setParameter("name", of: bake, to: .text("hit"))
            try project.connect(from: PinRef(node: round, pin: PinID(pin)), to: PinRef(node: bake, pin: "in"))
            bakes.append(bake)
        }
        let run = BatchRun(project: project, files: [source: (1...7).map { BatchFile(path: "/hits/\($0).wav") }])
        let writers = (0..<7).map { index in bakes.indices.filter { run.batchPass(index)?.node(bakes[$0]) != nil } }
        #expect(writers == [[0], [1], [2], [1], [0], [1], [2]])
        // Out 2 gets passes 2, 4 and 6: its own 1, 2, 3.
        #expect([1, 3, 5].map { run.fileName(of: bakes[1], pass: $0) } == ["hit_001", "hit_002", "hit_003"])
    }
}
