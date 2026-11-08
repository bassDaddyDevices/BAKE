import Testing
@testable import BakeGraph

/// Which cards show an out-of-date render: a node's fingerprint covers itself and everything feeding it.
struct UpstreamFingerprintsTests {
    private struct Chain {
        var project = ProjectFile()
        let audio: NodeID, reverse: NodeID, filters: NodeID, print: NodeID, unrelated: NodeID

        init() {
            var graph = TestGraph()
            audio = graph.add(.audio)
            reverse = graph.add(.reverse)
            filters = graph.add(.filters, ["cutoff": .number(900)])
            print = graph.add(.print)
            unrelated = graph.add(.lfo)
            graph.connect(audio, to: reverse)
            graph.connect(reverse, to: filters)
            graph.connect(filters, to: print)
            project = graph.project
        }
    }

    @Test func movingACardChangesNothing() {
        var chain = Chain()
        let before = chain.project.upstreamFingerprints()
        chain.project.moveNodes([chain.reverse, chain.filters], byX: 120, y: -40)
        #expect(chain.project.upstreamFingerprints() == before)
    }

    @Test func aChangedSettingChangesThatNodeAndThoseAfterItOnly() {
        var chain = Chain()
        let before = chain.project.upstreamFingerprints()
        chain.project.setParameter("cutoff", of: chain.filters, to: .number(400))
        let after = chain.project.upstreamFingerprints()
        #expect(after[chain.audio] == before[chain.audio])
        #expect(after[chain.reverse] == before[chain.reverse])
        #expect(after[chain.unrelated] == before[chain.unrelated])
        #expect(after[chain.filters] != before[chain.filters])
        #expect(after[chain.print] != before[chain.print])
    }

    @Test func aChangeUpstreamChangesEverythingDownstream() {
        var chain = Chain()
        let before = chain.project.upstreamFingerprints()
        chain.project.setParameter("mix", of: chain.reverse, to: .number(0.5))
        let after = chain.project.upstreamFingerprints()
        #expect(after[chain.audio] == before[chain.audio])
        #expect(after[chain.reverse] != before[chain.reverse])
        #expect(after[chain.filters] != before[chain.filters])
        #expect(after[chain.print] != before[chain.print])
        #expect(after[chain.unrelated] == before[chain.unrelated])
    }

    @Test func rewiringChangesTheNodesItFeeds() {
        var chain = Chain()
        let before = chain.project.upstreamFingerprints()
        let (reverse, audio, filters) = (chain.reverse, chain.audio, chain.filters)
        chain.project.edges.removeAll { $0.from.node == reverse }
        chain.project.edges.append(Edge(from: PinRef(node: audio, pin: "out"), to: PinRef(node: filters, pin: "in")))
        let after = chain.project.upstreamFingerprints()
        #expect(after[chain.audio] == before[chain.audio])
        #expect(after[chain.filters] != before[chain.filters])
    }

    @Test func aMovedSourceFileChangesTheAudioNodeAndWhatFollowsIt() {
        var chain = Chain()
        chain.project.assets = [AssetReference(id: testAsset, lastKnownPath: "/music/a.wav")]
        let before = chain.project.upstreamFingerprints()
        chain.project.assets = [AssetReference(id: testAsset, lastKnownPath: "/music/b.wav")]
        let after = chain.project.upstreamFingerprints()
        #expect(after[chain.audio] != before[chain.audio])
        #expect(after[chain.print] != before[chain.print])
        #expect(after[chain.unrelated] == before[chain.unrelated])
    }

    @Test func everyNodeGetsOneAndTheyAreStableForTheSameProject() {
        let chain = Chain()
        let first = chain.project.upstreamFingerprints()
        #expect(first.count == chain.project.nodes.count)
        #expect(first == chain.project.upstreamFingerprints())
    }

    @Test func aCycleDoesNotHangIt() {
        var graph = TestGraph()
        let a = graph.add(.filters)
        let b = graph.add(.filters)
        graph.connect(a, to: b)
        graph.connect(b, to: a)
        #expect(graph.project.upstreamFingerprints().count == 2)
    }
}
