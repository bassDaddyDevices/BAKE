import BakeDSP
import BakeGraph

/// Temporal Shatter on the CPU engine. The input is complete before the step runs, so the map is
/// analysed once, on the first chunk, into buffers sized here.
final class TemporalShatterProcessor: StepProcessor {
    private var controls: bake.dsp.TemporalShatterControls
    private let input: bake.dsp.AudioInput
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let outputFrames: Int
    private var states: [bake.dsp.TemporalShatterState]
    private var onsets: [Int]
    private var segments: [bake.dsp.TemporalShatterSegment]
    private var segmentCount = 0
    private var analysed = false

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let inputBinding = step.inputs["in"], let outputBinding = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var controls = bake.dsp.TemporalShatterControls()
        controls.attack = bake.dsp.ParameterSignal("attack", of: step, pool: pool)
        controls.sensitivity = bake.dsp.ParameterSignal("sensitivity", of: step, pool: pool)
        controls.grain = bake.dsp.ParameterSignal("grain", of: step, pool: pool)
        if case .choice("tape")? = step.parameters["mode"] { controls.mode = .tape } else { controls.mode = .grains }
        controls.sampleRate = sampleRate
        self.controls = controls
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        inputs = (0..<inputBinding.shape.channels).map { pool.channel($0, of: inputBinding) }
        outputs = (0..<outputBinding.shape.channels).map { pool.channel($0, of: outputBinding) }
        // The compiler's length is the truth; never recompute it.
        outputFrames = outputBinding.shape.frames
        states = Array(repeating: bake.dsp.TemporalShatterState(), count: outputs.count)
        let frames = inputBinding.shape.frames
        onsets = [Int](repeating: 0, count: bake.dsp.temporalShatterMaxOnsets(frames, sampleRate))
        segments = Array(repeating: bake.dsp.TemporalShatterSegment(), count: bake.dsp.temporalShatterMaxSegments(frames, sampleRate))
    }

    func process(frames: Range<Int>) async throws {
        if !analysed {
            segmentCount = onsets.withUnsafeMutableBufferPointer { onsetPointer in
                segments.withUnsafeMutableBufferPointer { segmentPointer in
                    bake.dsp.analyzeTemporalShatter(controls, input, outputFrames, onsetPointer.baseAddress, segmentPointer.baseAddress)
                }
            }
            analysed = true
        }
        for channel in outputs.indices {
            let source = inputs[min(channel, inputs.count - 1)]
            guard let samples = source.baseAddress, let destination = outputs[channel].baseAddress else { continue }
            segments.withUnsafeBufferPointer { segmentPointer in
                bake.dsp.renderTemporalShatter(
                    &states[channel], controls, segmentPointer.baseAddress, segmentCount, samples, source.count,
                    destination + frames.lowerBound, frames.lowerBound, frames.count
                )
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
