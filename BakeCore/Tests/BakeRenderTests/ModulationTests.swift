import BakeDSP
import Foundation
import Testing
@testable import BakeGPU
@testable import BakeGraph
@testable import BakeRender

struct ModulationTests {
    @Test func unmodulatedParametersHoldTheirKnobValue() {
        #expect(signal(1_000, 20, 20_000).valueAt(12_345) == 1_000)
    }

    @Test func linearModulationSpansTheRange() {
        let modulation: [Float] = [0, 0.5, -0.5, 1]
        modulation.withUnsafeBufferPointer { pointer in
            var gain = signal(0.5, 0, 1)
            gain.modulation = pointer.baseAddress
            gain.modulationFrames = pointer.count
            gain.trim = 0.5
            #expect(gain.valueAt(0) == 0.5)
            #expect(gain.valueAt(1) == 0.75)  // 0.5 + 0.5·0.5·1
            #expect(gain.valueAt(2) == 0.25)
            #expect(gain.valueAt(3) == 1)     // clamped
        }
    }

    @Test func exponentialModulationMovesInOctaves() {
        // Range 20…20,480 Hz is 10 octaves; +0.1 moves one octave up.
        let modulation: [Float] = [0.1, -0.1]
        modulation.withUnsafeBufferPointer { pointer in
            var cutoff = signal(1_000, 20, 20_480, scale: .exponential)
            cutoff.modulation = pointer.baseAddress
            cutoff.modulationFrames = pointer.count
            #expect(abs(cutoff.valueAt(0) - 2_000) < 0.01)
            #expect(abs(cutoff.valueAt(1) - 500) < 0.01)
        }
    }

    @Test func shortModulationSignalsHoldTheirLastValue() {
        let modulation: [Float] = [0, 1]
        modulation.withUnsafeBufferPointer { pointer in
            var mix = signal(0, 0, 1)
            mix.modulation = pointer.baseAddress
            mix.modulationFrames = pointer.count
            #expect(mix.valueAt(50) == 1)
        }
    }

    @Test func unwiredControlInputsReadTheirDefault() {
        var input = bake.dsp.ControlInput()
        input.unwired = 0.25
        #expect(input.valueAt(0) == 0.25)
        #expect(!input.isWired())
    }

    @Test func shortControlInputsHoldTheirLastValue() {
        let samples: [Float] = [0.5, -1]
        samples.withUnsafeBufferPointer { pointer in
            var input = bake.dsp.ControlInput()
            input.samples = pointer.baseAddress
            input.frames = pointer.count
            #expect(input.isWired())
            #expect(input.valueAt(0) == 0.5)
            #expect(input.valueAt(1_000_000) == -1)
        }
    }

    @Test func wiredPinsBecomeControlInputs() throws {
        let pool = try BufferPool(capacities: [2, 6], gpu: GPUContext())
        let short = BufferBinding(slot: 0, shape: SignalShape(frames: 2, channels: 1))
        pool.channel(0, of: short).update(repeating: 0.75)
        let step = RenderStep(
            node: NodeID(), kind: .filters, parameters: [:], modulationTrims: [:], assetID: nil,
            shape: SignalShape(frames: 6, channels: 1), inputs: ["amount": short], outputs: [:]
        )

        let wired = bake.dsp.ControlInput("amount", of: step, pool: pool)
        let missing = bake.dsp.ControlInput("trigger", of: step, pool: pool, unwired: 1)

        #expect(wired.frames == 2)
        #expect(wired.valueAt(5) == 0.75)
        #expect(missing.valueAt(5) == 1)
    }

    @Test func stepParametersBecomeSignalsWithPoolModulation() throws {
        let pool = try BufferPool(capacities: [4], gpu: GPUContext())
        let binding = BufferBinding(slot: 0, shape: SignalShape(frames: 4, channels: 1))
        pool.channel(0, of: binding).update(repeating: 0.1)
        let step = RenderStep(
            node: NodeID(), kind: .filters, parameters: ["cutoff": .number(1_000)],
            modulationTrims: ["cutoff": -1], assetID: nil,
            shape: SignalShape(frames: 4, channels: 1),
            inputs: ["mod.cutoff": binding], outputs: [:]
        )

        let cutoff = bake.dsp.ParameterSignal("cutoff", of: step, pool: pool)

        #expect(cutoff.minimum == 20)
        #expect(cutoff.maximum == 20_000)
        #expect(cutoff.scale == .exponential)
        #expect(cutoff.trim == -1)
        #expect(cutoff.modulationFrames == 4)
        #expect(abs(cutoff.valueAt(0) - 1_000 * pow(1_000, -0.1)) < 0.1)
    }
}
