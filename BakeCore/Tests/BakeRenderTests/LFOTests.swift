import BakeDSP
import Foundation
import Testing

struct LFOTests {
    /// Renders an LFO in the given chunk sizes (one call by default).
    private func render(
        _ shape: bake.dsp.LFOShape, rate: Float = 1, depth: Float = 1, phaseDegrees: Double = 0, seed: UInt32 = 0,
        frames: Int = 48_000, chunk: Int? = nil, reset: [Float]? = nil, clockSync: Bool = false, cycles: Double = 1
    ) -> [Float] {
        var state = bake.dsp.LFOState()
        state.phase = phaseDegrees / 360
        state.resetPhase = state.phase
        state.clockSync = clockSync
        state.cyclesPerBang = cycles
        state.random = seed
        let rateSignal = signal(rate, 0.01, 100, scale: .exponential)
        let depthSignal = signal(depth, 0, 1)
        var output = [Float](repeating: 0, count: frames)
        let resetValues = reset ?? []
        resetValues.withUnsafeBufferPointer { resetPointer in
            var resetInput = bake.dsp.ControlInput()
            if reset != nil { resetInput.samples = resetPointer.baseAddress; resetInput.frames = resetPointer.count }
            output.withUnsafeMutableBufferPointer { buffer in
                var start = 0
                while start < frames {
                    let count = min(chunk ?? frames, frames - start)
                    bake.dsp.renderLFO(&state, shape, rateSignal, depthSignal, resetInput, 48_000, buffer.baseAddress! + start, start, count)
                    start += count
                }
            }
        }
        return output
    }

    /// 1 for `length` frames from each start, else 0.
    private func bangs(at starts: [Int], length: Int = 100, frames: Int = 48_000) -> [Float] {
        var signal = [Float](repeating: 0, count: frames)
        for start in starts { for frame in start..<min(start + length, frames) { signal[frame] = 1 } }
        return signal
    }

    @Test func aBangRestartsTheCycle() {
        let output = render(.saw, reset: bangs(at: [10_000]))
        #expect(output[10_000] == 0)                              // saw starts at 0
        #expect(abs(output[11_200] - 0.05) < 1e-4)                // 1200 frames = 0.025 cycle at 1 Hz
        #expect(output[9_999] == render(.saw)[9_999])             // untouched before the bang
    }

    @Test func aBangRestartsAtThePhaseSetting() {
        let output = render(.sine, phaseDegrees: 90, reset: bangs(at: [20_000]))
        #expect(abs(output[20_000] - 1) < 1e-6)
    }

    @Test func aHeldResetFiresOnce() {
        let held = render(.saw, reset: bangs(at: [10_000], length: 38_000))
        let single = render(.saw, reset: bangs(at: [10_000]))
        #expect(held == single)
    }

    // MARK: Sync = Clock (bangs every 24000 frames unless noted)

    @Test func clockSyncRunsExactlyOneCyclePerBang() {
        let reset = bangs(at: [0, 24_000, 48_000], frames: 60_000)
        let output = render(.saw, frames: 60_000, reset: reset, clockSync: true)
        #expect(abs(output[30_000] - 0.5) < 1e-3)           // a quarter of the 24000-frame cycle
        #expect(abs(output[42_000] + 0.5) < 1e-3)           // three quarters
        #expect(output[48_000] == 0)
    }

    @Test func clockSyncRunsTwoCyclesOrHalfACyclePerBang() {
        let reset = bangs(at: [0, 24_000, 48_000], frames: 72_000)
        let twice = render(.saw, frames: 72_000, reset: reset, clockSync: true, cycles: 2)
        #expect(abs(twice[27_000] - 0.5) < 1e-3 && abs(twice[39_000] - 0.5) < 1e-3)
        let half = render(.saw, frames: 72_000, reset: reset, clockSync: true, cycles: 0.5)
        #expect(abs(half[54_000] - 0.25) < 1e-3)            // 1/8 of a 48000-frame cycle after the restart at 48000
        #expect(abs(half[66_000] - 0.75) < 1e-3)
    }

    @Test func onceLockedRateIsIgnored() {
        let reset = bangs(at: [0, 24_000, 48_000], frames: 60_000)
        let slow = render(.saw, rate: 1, frames: 60_000, reset: reset, clockSync: true)
        let fast = render(.saw, rate: 7, frames: 60_000, reset: reset, clockSync: true)
        #expect(Array(slow[24_000...]) == Array(fast[24_000...]))
    }

    @Test func clockSyncFollowsAChangeOfTempo() {
        let reset = bangs(at: [0, 24_000, 48_000, 60_000, 72_000], frames: 84_000)
        let output = render(.saw, frames: 84_000, reset: reset, clockSync: true)
        #expect(abs(output[63_000] - 0.5) < 1e-3)           // a quarter of the new 12000-frame gap
    }

    @Test func clockSyncWithoutBangsIsFree() {
        #expect(render(.sine, clockSync: true) == render(.sine))
    }

    @Test func clockSyncIsChunkInvariant() {
        let reset = bangs(at: [0, 777 * 9, 777 * 30 + 776, 40_000], frames: 48_000)
        #expect(render(.sampleAndHold, rate: 3, chunk: 777, reset: reset, clockSync: true, cycles: 2)
            == render(.sampleAndHold, rate: 3, reset: reset, clockSync: true, cycles: 2))
    }

    @Test func aBangOnAChunkBoundaryIsSeenOnce() {
        let reset = bangs(at: [777 * 3, 777 * 20 + 776])
        #expect(render(.sampleAndHold, rate: 3, seed: 5, chunk: 777, reset: reset) == render(.sampleAndHold, rate: 3, seed: 5, reset: reset))
        #expect(render(.saw, chunk: 777, reset: reset) == render(.saw, reset: reset))
    }

    @Test func sineFollowsItsRate() {
        let output = render(.sine)
        #expect(abs(output[0]) < 1e-6)
        #expect(abs(output[12_000] - 1) < 1e-4)   // quarter cycle of 1 Hz
        #expect(abs(output[36_000] + 1) < 1e-4)
    }

    @Test func shapesHaveTheirDocumentedForm() {
        #expect(abs(render(.triangle)[12_000] - 1) < 1e-4)
        #expect(abs(render(.triangle)[24_000]) < 1e-4)
        #expect(abs(render(.saw)[12_000] - 0.5) < 1e-4)
        #expect(render(.square)[6_000] == 1)
        #expect(render(.square)[30_000] == -1)
    }

    @Test func depthScalesTheOutput() {
        #expect(abs(render(.sine, depth: 0.25)[12_000] - 0.25) < 1e-4)
    }

    @Test func phaseOffsetShiftsTheStart() {
        #expect(abs(render(.sine, phaseDegrees: 90)[0] - 1) < 1e-6)
    }

    @Test func sampleAndHoldIsSteadyPerCycleAndSeeded() {
        let output = render(.sampleAndHold, rate: 4, frames: 48_000)
        #expect(Set(output[0..<12_000]).count == 1)          // one value per 1/4 s cycle
        #expect(output[0] != output[12_001])
        #expect(render(.sampleAndHold, rate: 4, seed: 7) == render(.sampleAndHold, rate: 4, seed: 7))
        #expect(render(.sampleAndHold, rate: 4, seed: 7) != render(.sampleAndHold, rate: 4, seed: 8))
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func chunkingDoesNotChangeTheWaveform(shapeIndex: Int32) throws {
        let shape = try #require(bake.dsp.LFOShape(rawValue: shapeIndex))
        #expect(render(shape, rate: 3.7, chunk: 997) == render(shape, rate: 3.7))
    }
}
