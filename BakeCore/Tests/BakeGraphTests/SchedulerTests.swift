import Testing
@testable import BakeGraph

struct SchedulerTests {
    @Test func graphWithoutPrintHasNoOutput() {
        var graph = TestGraph()
        graph.add(.audio)
        #expect(Scheduler.schedule(graph.project).errors == [.noOutput])
        #expect(Scheduler.schedule(ProjectFile()).errors == [.noOutput])
    }

    @Test func previewsAreScheduledLikeBakes() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let preview = graph.add(.preview)
        graph.connect(audio, to: preview)
        let result = Scheduler.schedule(graph.project)
        #expect(result.errors.isEmpty)
        #expect(result.order == [audio, preview])
    }

    @Test func chainRunsInSignalOrder() {
        var graph = TestGraph()
        let output = graph.add(.print) // created first on purpose
        let distortion = graph.add(.distortion)
        let audio = graph.add(.audio)
        graph.connect(distortion, to: output)
        graph.connect(audio, to: distortion)
        let result = Scheduler.schedule(graph.project)
        #expect(result.errors.isEmpty)
        #expect(result.order == [audio, distortion, output])
    }

    @Test func nodesNotFeedingAPrintAreSkipped() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let output = graph.add(.print)
        graph.add(.filters) // parked: nothing wired
        graph.connect(audio, to: output)
        let result = Scheduler.schedule(graph.project)
        #expect(result.errors.isEmpty) // the parked node's missing input is not an error
        #expect(result.order == [audio, output])
    }

    @Test func tiesGoToCreationOrderRegardlessOfEdgeOrder() {
        var graph = TestGraph()
        let audio = graph.add(.audio)
        let lfoA = graph.add(.lfo)
        let lfoB = graph.add(.lfo)
        let filters = graph.add(.filters, modulated: ["cutoff", "q"])
        let output = graph.add(.print)
        graph.connect(lfoB, to: filters, "mod.q")
        graph.connect(lfoA, to: filters, "mod.cutoff")
        graph.connect(audio, to: filters)
        graph.connect(filters, to: output)
        let expected = [audio, lfoA, lfoB, filters, output]
        #expect(Scheduler.schedule(graph.project).order == expected)

        graph.project.edges.reverse()
        #expect(Scheduler.schedule(graph.project).order == expected)
    }

    @Test func cyclesAreReported() {
        var graph = TestGraph()
        let a = graph.add(.filters)
        let b = graph.add(.distortion)
        let output = graph.add(.print)
        graph.connect(a, to: b)
        graph.connect(b, to: a)
        graph.connect(b, to: output)
        // The loop and everything downstream of it can't be ordered.
        #expect(Scheduler.schedule(graph.project).errors == [.cycle([a, b, output])])
    }

    @Test func requiredInputsMustBeConnected() {
        var graph = TestGraph()
        let filters = graph.add(.filters)
        let output = graph.add(.print)
        graph.connect(filters, to: output)
        #expect(Scheduler.schedule(graph.project).errors == [.missingInput(PinRef(node: filters, pin: "in"))])
    }
}
