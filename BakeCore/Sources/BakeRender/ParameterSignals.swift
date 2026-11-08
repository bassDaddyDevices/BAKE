import BakeDSP
import BakeGraph

extension bake.dsp.ParameterSignal {
    /// A step parameter as the C++ engine sees it: knob value, range, trim, scale, and — if its
    /// Page 2 pin is wired — a pointer to channel 0 of the modulation signal in the pool.
    /// A choice is its option's index (0…count − 1); kernels round it.
    init(_ parameter: ParameterID, of step: RenderStep, pool: BufferPool) {
        self.init()
        guard let definition = NodeCatalog.definition(for: step.kind).parameter(parameter) else { return }
        switch definition.kind {
        case .number(let range, _, _):
            base = Float(step.parameters[parameter]?.numberValue ?? range.lowerBound)
            minimum = Float(range.lowerBound)
            maximum = Float(range.upperBound)
        case .choice(let options, let defaultValue):
            let current: String = if case .choice(let value)? = step.parameters[parameter] { value } else { defaultValue }
            base = Float(options.firstIndex(of: current) ?? options.firstIndex(of: defaultValue) ?? 0)
            minimum = 0
            maximum = Float(max(options.count - 1, 0))
        case .text:
            return
        }
        trim = Float(step.modulationTrims[parameter] ?? 1)
        scale = definition.modulationScale == .exponential ? .exponential : .linear
        // A document saved before this range widened keeps the range its modulation was made against.
        if case .number = definition.kind,
           let legacy = LegacyModulationRanges.entry(kind: step.kind, parameter: parameter, parameters: step.parameters) {
            minimum = Float(legacy.range.lowerBound)
            maximum = Float(legacy.range.upperBound)
            scale = legacy.scale == .exponential ? .exponential : .linear
        }
        if let binding = step.inputs[NodeCatalog.modulationPinID(for: parameter)] {
            let channel = pool.channel(0, of: binding)
            modulation = UnsafePointer(channel.baseAddress)
            modulationFrames = channel.count
        }
    }
}

extension bake.dsp.ControlInput {
    /// Channel 0 of whatever is wired to `pin`, or `unwired` when nothing is.
    init(_ pin: PinID, of step: RenderStep, pool: BufferPool, unwired: Float = 0) {
        self.init()
        self.unwired = unwired
        if let binding = step.inputs[pin] {
            let channel = pool.channel(0, of: binding)
            samples = UnsafePointer(channel.baseAddress)
            frames = channel.count
        }
    }
}

extension bake.dsp.AudioInput {
    /// The channels wired to `pin` (up to 8), or an unwired input when nothing is.
    init(_ pin: PinID, of step: RenderStep, pool: BufferPool) {
        self.init()
        guard let binding = step.inputs[pin] else { return }
        let count = min(binding.shape.channels, Int(bake.dsp.maxAudioInputChannels))
        withUnsafeMutableBytes(of: &channels) { raw in
            let pointers = raw.bindMemory(to: UnsafePointer<Float>?.self)
            for channel in 0..<count {
                pointers[channel] = UnsafePointer(pool.channel(channel, of: binding).baseAddress)
            }
        }
        channelCount = count
        frames = binding.shape.frames
    }
}
