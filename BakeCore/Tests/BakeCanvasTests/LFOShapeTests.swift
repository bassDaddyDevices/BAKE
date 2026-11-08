import Testing
@testable import BakeCanvas

/// The drawing must match what BakeDSP/LFO.cpp renders.
struct LFOShapeTests {
    @Test func shapesMatchTheKernel() {
        #expect(abs(LFOShape.value("sine", at: 0.25, seed: 0) - 1) < 1e-9)
        #expect(LFOShape.value("triangle", at: 0.25, seed: 0) == 1)
        #expect(LFOShape.value("triangle", at: 0.75, seed: 0) == -1)
        #expect(LFOShape.value("saw", at: 0.25, seed: 0) == 0.5)
        #expect(LFOShape.value("saw", at: 0.75, seed: 0) == -0.5)
        #expect(LFOShape.value("square", at: 0.1, seed: 0) == 1)
        #expect(LFOShape.value("square", at: 0.6, seed: 0) == -1)
        // A second cycle repeats the first.
        #expect(LFOShape.value("saw", at: 1.25, seed: 0) == 0.5)
    }

    @Test func sampleAndHoldFollowsTheKernelsSequence() {
        // Seed 0: the kernel's first LCG step gives (1013904223 >> 8) / 2^24 * 2 - 1.
        let first = LFOShape.value("sampleAndHold", at: 0.1, seed: 0)
        #expect(abs(first - (-0.527864)) < 1e-4)
        // Held for the whole cycle, then a new value.
        #expect(LFOShape.value("sampleAndHold", at: 0.9, seed: 0) == first)
        #expect(LFOShape.value("sampleAndHold", at: 1.1, seed: 0) != first)
        #expect(LFOShape.value("sampleAndHold", at: 0.1, seed: 5) != first)
    }
}
