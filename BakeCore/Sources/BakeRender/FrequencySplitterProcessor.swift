import BakeDSP
import BakeGraph

/// Frequency Splitter on the CPU engine: every band is computed (each is what the lower ones left),
/// but only wired outputs are written.
final class FrequencySplitterProcessor: StepProcessor {
    private let controls: bake.dsp.FrequencySplitterControls
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    /// Band index → that output's channels, for the outputs this plan uses.
    private let bands: [Int: [UnsafeMutableBufferPointer<Float>]]
    private let channels: Int
    private var states: [bake.dsp.FrequencySplitterState]

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let input = step.inputs["in"] else { throw RenderError.unsupportedNode(step.kind) }
        var controls = bake.dsp.FrequencySplitterControls()
        controls.split1 = bake.dsp.ParameterSignal("split1", of: step, pool: pool)
        controls.split2 = bake.dsp.ParameterSignal("split2", of: step, pool: pool)
        controls.split3 = bake.dsp.ParameterSignal("split3", of: step, pool: pool)
        controls.split4 = bake.dsp.ParameterSignal("split4", of: step, pool: pool)
        var count = "3"
        if case .choice(let value)? = step.parameters["bands"] { count = value }
        controls.bands = Int32(count) ?? 3
        controls.sampleRate = sampleRate
        self.controls = controls
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        var bands: [Int: [UnsafeMutableBufferPointer<Float>]] = [:]
        for (pin, binding) in step.outputs {
            guard pin.hasPrefix("out"), let number = Int(pin.dropFirst(3)), number >= 1 else { continue }
            bands[number - 1] = (0..<binding.shape.channels).map { pool.channel($0, of: binding) }
        }
        self.bands = bands
        channels = bands.values.map(\.count).max() ?? input.shape.channels
        states = Array(repeating: bake.dsp.FrequencySplitterState(), count: max(channels, 1))
    }

    func process(frames: Range<Int>) async throws {
        for channel in 0..<channels {
            guard let source = inputs[min(channel, inputs.count - 1)].baseAddress else { continue }
            var targets = bake.dsp.FrequencySplitterOutputs()
            func at(_ band: Int) -> UnsafeMutablePointer<Float>? {
                guard let buffers = bands[band], channel < buffers.count, let base = buffers[channel].baseAddress else { return nil }
                return base + frames.lowerBound
            }
            targets.bands = (at(0), at(1), at(2), at(3), at(4))
            bake.dsp.renderFrequencySplitter(&states[channel], controls, source + frames.lowerBound, targets, frames.lowerBound, frames.count)
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
