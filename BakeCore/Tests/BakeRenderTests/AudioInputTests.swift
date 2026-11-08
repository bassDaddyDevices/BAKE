import BakeDSP
import Foundation
import Testing
@testable import BakeGPU
@testable import BakeGraph
@testable import BakeRender

struct AudioInputTests {
    @Test func unwiredInputsAreSilent() {
        let input = bake.dsp.AudioInput()
        #expect(!input.isWired())
        #expect(input.sample(0, 10) == 0)
        #expect(input.spread(1, 10) == 0)
    }

    @Test func inputsAreSilentPastTheirEndAndForMissingChannels() {
        let left: [Float] = [0.5, -0.25]
        left.withUnsafeBufferPointer { pointer in
            var input = bake.dsp.AudioInput()
            input.channels.0 = pointer.baseAddress
            input.channelCount = 1
            input.frames = 2
            #expect(input.isWired())
            #expect(input.sample(0, 1) == -0.25)
            #expect(input.sample(0, 2) == 0)       // past the end
            #expect(input.sample(1, 0) == 0)       // no such channel
            #expect(input.spread(1, 0) == 0.5)     // mono feeds every channel
        }
    }

    @Test func nonFiniteSamplesReadAsSilence() {
        let samples: [Float] = [.nan, .infinity]
        samples.withUnsafeBufferPointer { pointer in
            var input = bake.dsp.AudioInput()
            input.channels.0 = pointer.baseAddress
            input.channelCount = 1
            input.frames = 2
            #expect(input.sample(0, 0) == 0)
            #expect(input.sample(0, 1) == 0)
        }
    }

    @Test func wiredPinsBecomeAudioInputs() throws {
        let pool = try BufferPool(capacities: [6], gpu: GPUContext())
        let stereo = BufferBinding(slot: 0, shape: SignalShape(frames: 3, channels: 2))
        pool.channel(0, of: stereo).update(repeating: 0.25)
        pool.channel(1, of: stereo).update(repeating: -0.5)
        let step = RenderStep(
            node: NodeID(), kind: .mixer, parameters: [:], modulationTrims: [:], assetID: nil,
            shape: SignalShape(frames: 10, channels: 2), inputs: ["in1": stereo], outputs: [:]
        )

        let wired = bake.dsp.AudioInput("in1", of: step, pool: pool)
        let missing = bake.dsp.AudioInput("in2", of: step, pool: pool)

        #expect(wired.frames == 3 && wired.channelCount == 2)
        #expect(wired.sample(1, 2) == -0.5)
        #expect(wired.sample(1, 3) == 0)
        #expect(!missing.isWired())
    }
}
