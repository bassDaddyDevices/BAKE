import BakeGraph
import Testing
@testable import BakeCanvas

struct StressGraphTests {
    @Test func stressGraphHasAHundredWiredNodes() {
        let project = StressGraph.project()
        #expect(project.nodes.count == 100)
        #expect(project.edges.count == 80) // per row: 3 audio wires + 1 LFO wire
        // Every wire passes the editor's own rules when re-added.
        for edge in project.edges {
            var without = project
            without.removeEdge(edge)
            #expect(without.checkConnection(from: edge.from, to: edge.to) == nil)
        }
    }
}
