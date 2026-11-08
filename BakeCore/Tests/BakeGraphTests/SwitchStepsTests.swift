import Testing
@testable import BakeGraph

struct SwitchStepsTests {
    @Test func patternsAreOutputNumbersWithTheRestSkipped() {
        #expect(SwitchSteps.pattern("1 1 3 2 4", outputs: 4) == [0, 0, 2, 1, 3])
        #expect(SwitchSteps.pattern("0 9 x 2", outputs: 4) == [1])        // out of range and non-numbers skipped
        #expect(SwitchSteps.pattern("1,2, 3", outputs: 4) == [0, 1, 2])    // commas work too
        #expect(SwitchSteps.pattern("", outputs: 4).isEmpty)
    }

    @Test func forwardAndPingPong() {
        #expect(SwitchSteps.sequence(order: "forward", outputs: 4, count: 6) == [0, 1, 2, 3, 0, 1])
        #expect(SwitchSteps.sequence(order: "pingPong", outputs: 4, count: 8) == [0, 1, 2, 3, 2, 1, 0, 1])
        #expect(SwitchSteps.sequence(order: "pingPong", outputs: 2, count: 4) == [0, 1, 0, 1])
    }

    @Test func aPatternLoopsAndAnEmptyOneMeansForward() {
        #expect(SwitchSteps.sequence(order: "pattern", outputs: 4, pattern: [0, 0, 2], count: 6) == [0, 0, 2, 0, 0, 2])
        #expect(SwitchSteps.sequence(order: "pattern", outputs: 3, pattern: [], count: 4) == [0, 1, 2, 0])
    }

    @Test func randomIsSeededAndNeverRepeatsTheCurrentOutput() {
        let steps = SwitchSteps.sequence(order: "random", outputs: 4, seed: 7, count: 200)
        #expect(steps.allSatisfy { (0..<4).contains($0) })
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 != $1 })
        #expect(Set(steps) == [0, 1, 2, 3])
        #expect(SwitchSteps.sequence(order: "random", outputs: 4, seed: 7, count: 200) == steps)
        #expect(SwitchSteps.sequence(order: "random", outputs: 4, seed: 8, count: 200) != steps)
        // With two outputs, never repeating means alternating.
        let two = SwitchSteps.sequence(order: "random", outputs: 2, seed: 3, count: 6)
        #expect(zip(two, two.dropFirst()).allSatisfy { $0 != $1 })
    }
}
