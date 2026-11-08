import BakeDSP
import Testing
@testable import BakeGraph
@testable import BakeRender

/// An Envelope with nothing on Trigger repeats every Every ms (issue 001's rule: timing and
/// modulation nodes never just run once). At 48 kHz, 100 ms is 4800 frames.
struct EnvelopeRepeatTests {
    /// Attack 10 ms, Decay 10 ms, Sustain 0.5, Release 10 ms: peak 479 frames after each bang (the bang
    /// frame is the attack's first), done 30 ms after it.
    private func render(frames: Int = 24_000, every: Double?, trigger: [Float]? = nil, chunk: Int? = nil) -> [Float] {
        let attack = signal(0.01, 0.001, 10), decay = signal(0.01, 0.001, 10)
        let sustain = signal(0.5, 0, 1), release = signal(0.01, 0.001, 10), timeScale = signal(1, 0.1, 10)
        var everySignal = signal(Float(every ?? 1_000), 10, 30_000)
        var state = bake.dsp.EnvelopeState()
        var output = [Float](repeating: 0, count: frames)
        let triggerValues = trigger ?? []
        triggerValues.withUnsafeBufferPointer { triggerPointer in
            output.withUnsafeMutableBufferPointer { destination in
                var input = bake.dsp.ControlInput()
                if trigger != nil { input.samples = triggerPointer.baseAddress; input.frames = triggerPointer.count }
                var start = 0
                while start < frames {
                    let count = min(chunk ?? frames, frames - start)
                    if every != nil {
                        bake.dsp.renderEnvelope(
                            &state, .exponential, .off, .oneShot, attack, decay, sustain, release, timeScale, input, &everySignal,
                            48_000, destination.baseAddress! + start, start, count
                        )
                    } else {
                        bake.dsp.renderEnvelope(
                            &state, .exponential, .off, .oneShot, attack, decay, sustain, release, timeScale, input,
                            48_000, destination.baseAddress! + start, start, count
                        )
                    }
                    start += count
                }
            }
        }
        return output
    }

    @Test func unwiredItFiresEveryEveryMs() {
        let output = render(every: 100)
        for bang in stride(from: 0, to: 24_000, by: 4_800) {
            #expect(output[bang + 479] == 1, "peak after the bang at \(bang)")
            #expect(output[bang + 3_000] == 0, "silent before the next bang")
        }
    }

    @Test func onceRunsAtTheStartOnly() {
        let output = render(every: nil)
        #expect(output[479] == 1)
        #expect(output[4_800 + 480] == 0)
    }

    @Test func aWiredTriggerStillDecides() {
        var trigger = [Float](repeating: 0, count: 24_000)
        for frame in 10_000..<10_050 { trigger[frame] = 1 }
        let output = render(every: 100, trigger: trigger)
        #expect(output[480] == 0)
        #expect(output[4_800 + 480] == 0)
        #expect(output[10_479] == 1)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        #expect(render(every: 37, chunk: 777) == render(every: 37))
    }

    @Test func newEnvelopesRepeatAndSavedOnesRunOnce() {
        #expect(NodeCatalog.defaultParameters(for: .envelope)["repeat"] == .choice("every"))
        var saved = ProjectFile(schemaVersion: 5, nodes: [Node(kind: .envelope)])
        ProjectMigration.migrate(&saved)
        #expect(saved.nodes[0].parameters["repeat"] == .choice("once"))
    }
}
