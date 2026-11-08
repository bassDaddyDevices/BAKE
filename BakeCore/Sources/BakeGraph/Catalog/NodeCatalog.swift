/// The v1 node types: their pins, parameters, and length rules.
/// See wiki/modules/node-catalog.md for the full catalog and later waves.
public enum NodeCatalog {
    public static func definition(for kind: NodeKind) -> NodeDefinition {
        switch kind {
        case .audio: audioDefinition
        case .stretch: stretchDefinition
        case .reverse: reverseDefinition
        case .filters: filtersDefinition
        case .distortion: distortionDefinition
        case .flanger: flangerDefinition
        case .phaser: phaserDefinition
        case .redux: reduxDefinition
        case .waveshaper: waveshaperDefinition
        case .wavefolder: wavefolderDefinition
        case .derivativeDistortion: derivativeDistortionDefinition
        case .residualExplosion: residualExplosionDefinition
        case .subHarmonic: subHarmonicDefinition
        case .tapeDegrade: tapeDegradeDefinition
        case .dualFilter: dualFilterDefinition
        case .adaptiveClipping: adaptiveClippingDefinition
        case .frequencySplitter: frequencySplitterDefinition
        case .granularCloud: granularCloudDefinition
        case .temporalShatter: temporalShatterDefinition
        case .gainVCA: gainVCADefinition
        case .resonator: resonatorDefinition
        case .print: printDefinition
        case .batchAudio: batchAudioDefinition
        case .batchBake: batchBakeDefinition
        case .largeAudio: largeAudioDefinition
        case .concatenate: concatenateDefinition
        case .corpusScatter: corpusScatterDefinition
        case .ensembleAverager: ensembleAveragerDefinition
        case .combinatorialMatrix: combinatorialMatrixDefinition
        case .forEachSplitter: forEachSplitterDefinition
        case .spectralSorter: spectralSorterDefinition
        case .merryGoRound: merryGoRoundDefinition
        case .photoBooth: photoBoothDefinition
        case .batchConform: batchConformDefinition
        case .preview: previewDefinition
        case .mixer: mixerDefinition
        case .channelSplitter: channelSplitterDefinition
        case .channelMerger: channelMergerDefinition
        case .stepSwitch: stepSwitchDefinition
        case .stepSwitchFanOut: stepSwitchFanOutDefinition
        case .feedback: feedbackDefinition
        case .lfo: lfoDefinition
        case .random: randomDefinition
        case .sampleAndHold: sampleAndHoldDefinition
        case .generator: generatorDefinition
        case .delay: delayDefinition
        case .convolver: convolverDefinition
        case .reverb: reverbDefinition
        case .compressor: compressorDefinition
        case .limiter: limiterDefinition
        case .frequencyShifter: frequencyShifterDefinition
        case .otftCompressor: otftCompressorDefinition
        case .utility: utilityDefinition
        case .macro: macroDefinition
        case .envelope: envelopeDefinition
        case .envelopeFollower: envelopeFollowerDefinition
        case .pitchFollower: pitchFollowerDefinition
        case .transientDetector: transientDetectorDefinition
        case .featureFollower: featureFollowerDefinition
        case .clock: clockDefinition
        case .chorus: chorusDefinition
        case .midSideEncoder: midSideEncoderDefinition
        case .midSideDecoder: midSideDecoderDefinition
        case .math: mathDefinition
        case .logic: logicDefinition
        case .quantizer: quantizerDefinition
        case .vocoder: vocoderDefinition
        case .spectralResynthesis: spectralResynthesisDefinition
        case .fractalFilter: fractalFilterDefinition
        case .singleCycle: singleCycleDefinition
        case .wavetableFactory: wavetableFactoryDefinition
        case .halfTime: halfTimeDefinition
        case .beatRepeat: beatRepeatDefinition
        case .looper: looperDefinition
        case .stutter: stutterDefinition
        case .stepFX: stepFXDefinition
        case .custom: customDefinition
        case .customInput: customInputDefinition
        case .customOutput: customOutputDefinition
        }
    }

    /// Every parameter at its default. New nodes store these, so later default changes never
    /// alter existing documents.
    public static func defaultParameters(for kind: NodeKind) -> [ParameterID: ParameterValue] {
        Dictionary(definition(for: kind).parameters.map { ($0.id, $0.defaultValue) }, uniquingKeysWith: { first, _ in first })
    }

    public static func modulationPinID(for parameter: ParameterID) -> PinID {
        "mod.\(parameter)"
    }

    /// The parameter a spawned `mod.<parameter>` pin modulates, or nil for fixed pins.
    public static func parameter(forModulationPin pin: PinID) -> ParameterID? {
        pin.hasPrefix("mod.") ? String(pin.dropFirst(4)) : nil
    }

    /// The signal an output pin of `kind` carries: a fixed pin, or any pin of a repeated output group
    /// (`out3` of a Channel Splitter or Macro). Nil if `kind` has no such output.
    public static func outputSignal(_ pin: PinID, of kind: NodeKind) -> SignalType? {
        let definition = definition(for: kind)
        if let fixed = definition.pins.first(where: { $0.direction == .output && $0.id == pin }) {
            return fixed.signal
        }
        return definition.repeated.first { $0.direction == .output && $0.number(of: pin) != nil }?.signal
    }

    /// The signals of every output `kind` can have, fixed and repeated.
    public static func outputSignals(of kind: NodeKind) -> [SignalType] {
        let definition = definition(for: kind)
        return definition.pins.filter { $0.direction == .output }.map(\.signal)
            + definition.repeated.filter { $0.direction == .output }.map(\.signal)
    }

    /// Whether `node` is causal: its output at frame n uses only inputs at frames ≤ n, and it never
    /// analyses its whole input first. Only causal nodes may sit inside a feedback loop, which renders
    /// in blocks no longer than the loop's delay. Each listed kind is proven by `FeedbackCausalityTests`.
    public static func isCausal(_ node: Node) -> Bool {
        let parameters = resolvedParameters(of: node)
        switch node.kind {
        case .filters:
            return parameters["phase"] == .choice("minimum")
        case .distortion, .waveshaper, .wavefolder:
            return parameters["oversampling"] == .choice("1")
        case .dualFilter, .redux, .gainVCA, .phaser, .flanger, .chorus, .subHarmonic, .frequencySplitter,
             .mixer, .channelSplitter, .channelMerger, .midSideEncoder, .midSideDecoder, .stepSwitch, .stepSwitchFanOut,
             .delay, .lfo, .random, .sampleAndHold, .envelope, .envelopeFollower, .clock, .math, .logic, .quantizer, .macro, .preview, .print:
            return true
        default:
            return false
        }
    }

    /// The feedback-delay of a Feedback node in frames: at least one.
    public static func feedbackDelayFrames(_ node: Node, sampleRate: Double) -> Int {
        let milliseconds = resolvedParameters(of: node)["delay"]?.numberValue ?? 10
        return max(1, Int((milliseconds * 0.001 * sampleRate).rounded()))
    }

    /// The node's fixed pins, its repeated pins at their current count, then one control input per
    /// modulatable parameter ticked on Page 2.
    public static func pins(of node: Node) -> [PinDefinition] {
        if let boundary = boundaryPins(of: node) { return boundary }
        let definition = definition(for: node.kind)
        let repeated = definition.repeated.flatMap { group in
            (1...max(pinCount(of: group, on: node), 1)).map {
                PinDefinition(id: group.id($0), direction: group.direction, signal: group.signal, isRequired: false, channels: group.channels)
            }
        }
        let spawned = node.modulated.compactMap { parameterID -> PinDefinition? in
            guard definition.parameter(parameterID)?.isModulatable == true else { return nil }
            return PinDefinition(id: modulationPinID(for: parameterID), direction: .input, signal: .control, isRequired: false)
        }
        return definition.pins + repeated + spawned
    }

    /// How many pins a repeated group has on this node right now.
    public static func pinCount(of group: RepeatedPins, on node: Node) -> Int {
        let values = resolvedParameters(of: node)
        switch group.count {
        case .parameter(let id):
            if case .choice(let choice)? = values[id], let count = Int(choice) { return count }
            return 1
        case .growing(let id, let minimum, let maximum):
            return min(max(Int(values[id]?.numberValue ?? Double(minimum)), minimum), maximum)
        }
    }

    /// What a pin is called on the card: "In"/"Out", a repeated pin's label ("L", "In 2"), or the
    /// modulated parameter's name.
    public static func label(of pin: PinID, on node: Node) -> String {
        if node.kind == .customInput || node.kind == .customOutput {
            return node.ports?.first { $0.id == pin }?.name ?? ""
        }
        let definition = definition(for: node.kind)
        if let parameter = parameter(forModulationPin: pin) {
            return definition.parameter(parameter)?.name ?? parameter
        }
        for group in definition.repeated {
            guard let number = group.number(of: pin) else { continue }
            let count = pinCount(of: group, on: node)
            if let names = group.labels[count], number <= names.count { return names[number - 1] }
            return "\(group.direction == .input ? "In" : "Out") \(number)"
        }
        if let fixed = definition.pins.first(where: { $0.id == pin }) {
            // "in" and "out" read as In / Out; any other fixed pin shows its name (Reset, Trigger, A).
            if pin == "in" || pin == "out" { return fixed.direction == .input ? "In" : "Out" }
            return pin.prefix(1).uppercased() + pin.dropFirst()
        }
        return pin
    }

    /// Checks a stored value against its definition. Missing values become the default;
    /// numbers are clamped into range. Returns nil for a wrong type, non-finite number, or unknown choice.
    public static func resolve(_ value: ParameterValue?, for parameter: ParameterDefinition) -> ParameterValue? {
        guard let value else { return parameter.defaultValue }
        switch (parameter.kind, value) {
        case let (.number(range, _, _), .number(number)):
            guard number.isFinite else { return nil }
            return .number(min(max(number, range.lowerBound), range.upperBound))
        case let (.choice(options, _), .choice(choice)):
            return options.contains(choice) ? value : nil
        case (.text, .text):
            return value
        default:
            return nil
        }
    }

    /// Every parameter of the node, with defaults filled in and numbers clamped.
    public static func resolvedParameters(of node: Node) -> [ParameterID: ParameterValue] {
        var resolved: [ParameterID: ParameterValue] = [:]
        for parameter in definition(for: node.kind).parameters {
            resolved[parameter.id] = resolve(node.parameters[parameter.id], for: parameter) ?? parameter.defaultValue
        }
        return resolved
    }

    /// The parameters a card shows for `node`, in catalog order: not hidden, and any `shownWhen`
    /// rule met by the node's current (resolved) choices.
    public static func visibleParameters(of node: Node) -> [ParameterDefinition] {
        let values = resolvedParameters(of: node)
        return definition(for: node.kind).parameters.filter { parameter in
            guard parameter.role != .hidden else { return false }
            guard let rule = parameter.shownWhen else { return true }
            guard case .choice(let current)? = values[rule.parameter] else { return false }
            return rule.values.contains(current)
        }
    }

    // MARK: - Pins

    private static let audioIn = PinDefinition(id: "in", direction: .input, signal: .audio, isRequired: true)
    private static let audioOut = PinDefinition(id: "out", direction: .output, signal: .audio, isRequired: false)
    private static let envelopeTriggerIn = PinDefinition(id: "trigger", direction: .input, signal: .control, isRequired: false)
    private static let gainAmountIn = PinDefinition(id: "amount", direction: .input, signal: .control, isRequired: false)
    private static let controlOut = PinDefinition(id: "out", direction: .output, signal: .control, isRequired: false)

    // MARK: - v1 definitions

    private static let audioDefinition = NodeDefinition(
        kind: .audio,
        pins: [audioOut],
        parameters: [
            .number("gain", "Gain", -60...24, default: 0, unit: "dB", modulatable: true),
            .number("cropStart", "Start", 0...1, default: 0),
            .number("cropEnd", "End", 0...1, default: 1),
            .number("loopCount", "Loops", 1...64, default: 1, integer: true),
            .choice("interpolation", "Interpolation", ["linear", "hermite", "sinc"], default: "sinc", role: .setting),
        ],
        lengthRule: .asset
    )

    private static let reverseDefinition = NodeDefinition(
        kind: .reverse,
        pins: [audioIn, audioOut],
        parameters: [
            .choice("mode", "Mode", ["global"], default: "global", role: .setting),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Plays each window of its input slower from where the window starts, then jumps back to the
    /// present for the next window: half time and slower. Windows run on a timer, or on bangs at Sync.
    private static let halfTimeDefinition = NodeDefinition(
        kind: .halfTime,
        pins: [
            audioIn,
            PinDefinition(id: "sync", direction: .input, signal: .control, isRequired: false),
            audioOut,
        ],
        parameters: [
            .number("speed", "Speed", 0.001...1, default: 0.5, unit: "×", modulatable: true, scale: .exponential,
                    taper: .power(2)),
            .number("window", "Window", 10...8_000, default: 500, unit: "ms", modulatable: true, scale: .exponential),
            .choice("mode", "Mode", ["repitch", "granular"], default: "repitch"),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .number("smooth", "Smooth", 0...50, default: 5, unit: "ms", role: .setting, modulatable: true,
                    shownWhen: ParameterCondition("mode", in: ["repitch"])),
            .number("grain", "Grain", 5...200, default: 40, unit: "ms", role: .setting, modulatable: true,
                    shownWhen: ParameterCondition("mode", in: ["granular"])),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Ableton-style Beat Repeat with its own tempo: once per Interval (or on each Trigger bang), with
    /// probability Chance, a Grid-long slice repeats for the Gate. Capture takes the slice from ahead
    /// (the future) or behind; Accelerate, Pitch Drift and Decay change each repeat.
    /// Ableton-style Beat Repeat with its own tempo: once per Interval (or on each Trigger bang), with
    /// probability Chance, a Grid-long slice repeats for the Gate. Capture takes the slice from ahead
    /// (the future) or behind; Accelerate, Pitch Drift and Decay change each repeat. Everything but
    /// Mode and Seed can be modulated: event values are read as each event starts, repeat values as
    /// each repeat starts, and the timer follows Tempo, Interval and Offset continuously.
    private static let beatRepeatDefinition = NodeDefinition(
        kind: .beatRepeat,
        pins: [
            audioIn,
            PinDefinition(id: "trigger", direction: .input, signal: .control, isRequired: false),
            audioOut,
        ],
        parameters: [
            .choice("grid", "Grid", BeatRepeatNotes.grids, default: "1/16", modulatable: true),
            .number("gate", "Gate", 1...64, default: 4, unit: "/16", modulatable: true, integer: true),
            .number("chance", "Chance", 0...1, default: 1, modulatable: true),
            .choice("mode", "Mode", ["insert", "mix", "gate"], default: "insert"),
            .number("accelerate", "Accelerate", 0.5...2, default: 1, unit: "×", modulatable: true),
            .number("pitch", "Pitch", -48...24, default: 0, unit: "st", modulatable: true),
            .number("decay", "Decay", 0...1, default: 0, modulatable: true),
            .number("tempo", "Tempo", 20...300, default: 120, unit: "BPM", role: .setting, modulatable: true),
            .choice("interval", "Interval", BeatRepeatNotes.intervals, default: "1/1", role: .setting, modulatable: true),
            .number("offset", "Offset", 0...15, default: 8, unit: "/16", role: .setting, modulatable: true, integer: true),
            .number("capture", "Capture", -16...16, default: 0, unit: "grids", role: .setting, modulatable: true, integer: true),
            .number("pitchDrift", "Pitch Drift", -12...12, default: 0, unit: "st", role: .setting, modulatable: true),
            .number("variation", "Variation", 0...1, default: 0, role: .setting, modulatable: true),
            .number("seed", "Seed", 0...999_999, default: 0, role: .setting, integer: true),
            .number("smooth", "Smooth", 0...20, default: 2, unit: "ms", role: .setting, modulatable: true),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Repeats a region of its input Passes times, then lets the input carry on (or keeps only the
    /// loop). Start, Length, Passes, Shrink and Keep set the output length, so they are fixed when the
    /// graph compiles (`LooperPlan`); everything a pass does is modulatable, read as each pass starts.
    private static let looperDefinition = NodeDefinition(
        kind: .looper,
        pins: [
            audioIn,
            PinDefinition(id: "trigger", direction: .input, signal: .control, isRequired: false),
            audioOut,
        ],
        parameters: [
            // Repeat: each bang on Trigger (or every Every ms) loops the next Length until the next
            // bang, and the output is as long as the input. Once: one region looped Passes times.
            .choice("mode", "Mode", ["repeat", "once"], default: "repeat"),
            .number("every", "Every", 10...30_000, default: 2_000, unit: "ms", modulatable: true, scale: .exponential,
                    shownWhen: ParameterCondition("mode", in: ["repeat"])),
            .number("start", "Start", 0...1, default: 0, shownWhen: ParameterCondition("mode", in: ["once"])),
            .number("length", "Length", 1...30_000, default: 500, unit: "ms", scale: .exponential),
            .number("passes", "Passes", 1...256, default: 4, integer: true),
            .number("shrink", "Shrink", 0.5...2, default: 1, unit: "×"),
            .choice("direction", "Direction", ["forward", "reverse", "pingPong"], default: "forward", modulatable: true),
            .number("scrub", "Scrub", -2_000...2_000, default: 0, unit: "ms", modulatable: true),
            .number("pitch", "Pitch", -24...24, default: 0, unit: "st", modulatable: true),
            .number("decay", "Decay", 0...1, default: 0, modulatable: true),
            .choice("keep", "Keep", ["whole", "loop"], default: "whole", role: .setting,
                    shownWhen: ParameterCondition("mode", in: ["once"])),
            .number("pitchDrift", "Pitch Drift", -12...12, default: 0, unit: "st", role: .setting, modulatable: true),
            .number("crossfade", "Crossfade", 0...200, default: 10, unit: "ms", role: .setting, modulatable: true),
            .choice("snap", "Snap", ["on", "off"], default: "on", role: .setting),
        ],
        lengthRule: .looped("in")
    )

    /// Bursts of micro-repeats in ms, fired by bangs on Trigger or every Every ms: a Size-long slice
    /// plays Repeats times, each one shrinking, chopped by Gate, decaying, drifting in pitch and across
    /// the stereo field, jittered and reversed at will. Everything but Seed is modulatable.
    private static let stutterDefinition = NodeDefinition(
        kind: .stutter,
        pins: [
            audioIn,
            PinDefinition(id: "trigger", direction: .input, signal: .control, isRequired: false),
            audioOut,
        ],
        parameters: [
            .number("size", "Size", 1...1_000, default: 60, unit: "ms", modulatable: true, scale: .exponential),
            .number("repeats", "Repeats", 1...256, default: 8, modulatable: true, integer: true),
            .number("shrink", "Shrink", 0.5...2, default: 1, unit: "×", modulatable: true),
            .number("gate", "Gate", 0.05...1, default: 1, modulatable: true),
            .number("decay", "Decay", 0...1, default: 0, modulatable: true),
            .number("pitchDrift", "Pitch Drift", -12...12, default: 0, unit: "st", modulatable: true),
            .number("panDrift", "Pan Drift", -1...1, default: 0, modulatable: true),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .number("every", "Every", 10...10_000, default: 1_000, unit: "ms", role: .setting, modulatable: true, scale: .exponential),
            .number("chance", "Chance", 0...1, default: 1, role: .setting, modulatable: true),
            .number("capture", "Capture", -1_000...1_000, default: 0, unit: "ms", role: .setting, modulatable: true),
            .number("pitch", "Pitch", -24...24, default: 0, unit: "st", role: .setting, modulatable: true),
            .number("pan", "Pan", -1...1, default: 0, role: .setting, modulatable: true),
            .choice("reverse", "Reverse", ["off", "alternate", "all"], default: "off", role: .setting, modulatable: true),
            .number("jitter", "Jitter", 0...100, default: 0, unit: "ms", role: .setting, modulatable: true),
            .number("smooth", "Smooth", 0...20, default: 2, unit: "ms", role: .setting, modulatable: true),
            .number("seed", "Seed", 0...999_999, default: 0, role: .setting, integer: true),
            // Which range modulation of this node's controls spans: documents saved before the ranges widened keep
            // the old ones (see LegacyModulationRanges).
            .choice("modulationRange", "Modulation Range", ["current", "legacy"], default: "current", role: .hidden),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// A step sequencer of time effects: each step of the pattern (`StepFXPattern`) passes, stutters,
    /// reverses, tape-stops, half-times or gates its own audio. Bangs on Clock start the steps (with
    /// look-ahead to the next bang for the step length), or its own Tempo and Step do. Seeded Chance
    /// and Variation and a modulatable Rotate vary the pattern; everything but Steps, the pattern
    /// and Seed is modulatable.
    private static let stepFXDefinition = NodeDefinition(
        kind: .stepFX,
        pins: [
            audioIn,
            PinDefinition(id: "clock", direction: .input, signal: .control, isRequired: false),
            audioOut,
        ],
        parameters: [
            .number("steps", "Steps", 1...32, default: 16, integer: true),
            .number("chance", "Chance", 0...1, default: 1, modulatable: true),
            .number("variation", "Variation", 0...1, default: 0, modulatable: true),
            .number("rotate", "Rotate", -32...32, default: 0, modulatable: true, integer: true),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .text("pattern", "Pattern", default: "· · S · · · R · · · H · S S T ·"),
            .number("tempo", "Tempo", 20...300, default: 120, unit: "BPM", role: .setting, modulatable: true),
            .choice("step", "Step", StepFXPattern.stepLengths, default: "1/16", role: .setting, modulatable: true),
            .number("stutterSize", "Stutter Size", 1...500, default: 30, unit: "ms", role: .setting, modulatable: true, scale: .exponential),
            .number("speed", "Speed", 0.05...1, default: 0.5, unit: "×", role: .setting, modulatable: true),
            .number("curve", "Curve", 0.25...4, default: 1, role: .setting, modulatable: true),
            .number("gate", "Gate", 0.05...1, default: 0.5, role: .setting, modulatable: true),
            .number("smooth", "Smooth", 0...20, default: 2, unit: "ms", role: .setting, modulatable: true),
            .number("seed", "Seed", 0...999_999, default: 0, role: .setting, integer: true),
        ],
        lengthRule: .sameAsInput("in")
    )

    private static let stretchDefinition = NodeDefinition(
        kind: .stretch,
        pins: [audioIn, audioOut],
        parameters: [
            .number("ratio", "Ratio", 0.1...1000, default: 1, unit: "×"),
            .number("pitchSemitones", "Pitch", -24...24, default: 0, unit: "st", modulatable: true),
            .number("pitchCents", "Fine", -100...100, default: 0, unit: "ct", modulatable: true),
            .choice("fftSize", "FFT Size", ["1024", "2048", "4096", "8192"], default: "4096", role: .setting),
        ],
        lengthRule: .scaledInput("in", by: "ratio")
    )

    private static let filtersDefinition = NodeDefinition(
        kind: .filters,
        pins: [audioIn, audioOut],
        parameters: [
            .choice("type", "Type", ["lowpass", "highpass", "bandpass", "notch"], default: "lowpass", modulatable: true),
            .number("cutoff", "Cutoff", 20...20_000, default: 1_000, unit: "Hz", modulatable: true, scale: .exponential),
            .number("q", "Resonance", 0.1...20, default: 0.707, modulatable: true),
            .number("drive", "Drive", 0...24, default: 0, unit: "dB", modulatable: true),
            // Minimum phase is the biquad cascade; Linear is a FIR with no phase shift and no delay.
            .choice("phase", "Phase", ["minimum", "linear"], default: "minimum"),
            .choice("slope", "Slope", ["12", "24", "48", "96"], default: "24", role: .setting),
            // Linear phase only: more taps, a steeper edge. 131073 taps is a 1.6 Hz edge at 48 kHz.
            .choice("firTaps", "FIR Length", ["1025", "4097", "16385", "65537", "131073"], default: "4097", role: .setting,
                    shownWhen: ParameterCondition("phase", in: ["linear"])),
        ],
        lengthRule: .sameAsInput("in")
    )

    private static let flangerDefinition = NodeDefinition(
        kind: .flanger,
        pins: [audioIn, audioOut],
        parameters: [
            // Through-zero sweeps the wet head from +Delay to −Delay at full Depth, so Delay is how far it reaches either way.
            .number("delay", "Delay", 0.1...50, default: 4, unit: "ms", modulatable: true, scale: .exponential),
            .number("rate", "Rate", 0.05...5, default: 0.25, unit: "Hz", modulatable: true, scale: .exponential),
            .number("depth", "Depth", 0...1, default: 0.7, modulatable: true),
            .number("feedback", "Feedback", 0...0.95, default: 0.35, modulatable: true),
            .number("mix", "Mix", 0...1, default: 0.5, modulatable: true),
            .choice("feedbackPolarity", "Feedback Polarity", ["positive", "negative"], default: "positive", role: .setting),
            .number("hfDamping", "HF Damping", 0...0.95, default: 0.2, role: .setting, modulatable: true),
            .choice("interpolation", "Interpolation", ["linear", "cubic"], default: "cubic", role: .setting),
            // Read Head: causal = the original delay line; throughZero = the wet head reads the whole input and can
            // pass through zero into its future. New nodes are throughZero; saved documents stay causal.
            .choice("readHead", "Read Head", ["causal", "throughZero"], default: "throughZero", role: .setting),
            // Wet Polarity: negative cancels the dry signal as the head crosses zero (the jet whoosh).
            .choice("wetPolarity", "Wet Polarity", ["positive", "negative"], default: "positive", role: .setting,
                    shownWhen: ParameterCondition("readHead", in: ["throughZero"])),
            // Dispersion: all-pass sections run over the whole channel before the sweep, so higher frequencies lag
            // and the comb's notches stop being harmonic and sweep as chirps.
            .number("dispersion", "Dispersion", 0...1, default: 0, role: .setting,
                    shownWhen: ParameterCondition("readHead", in: ["throughZero"])),
            .choice("modulationRange", "Modulation Range", ["current", "legacy"], default: "current", role: .hidden),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Sweeps on its own (Rate, Depth); Center and Width set the sweep's middle and spread.
    private static let phaserDefinition = NodeDefinition(
        kind: .phaser,
        pins: [audioIn, audioOut],
        parameters: [
            .number("center", "Center", 80...8_000, default: 700, unit: "Hz", modulatable: true, scale: .exponential),
            .number("width", "Width", 0.25...4, default: 2, unit: "oct", modulatable: true),
            .choice("stages", "Stages", ["2", "4", "8", "12", "24", "36", "48", "64", "96", "128", "256", "512"], default: "4"),
            .number("rate", "Rate", 0.05...5, default: 0.3, unit: "Hz", modulatable: true, scale: .exponential),
            .number("depth", "Depth", 0...1, default: 0.6, modulatable: true),
            .number("feedback", "Feedback", -0.95...0.95, default: 0.2, modulatable: true),
            .number("mix", "Mix", 0...1, default: 0.5, modulatable: true),
            .number("stereoOffset", "Stereo Offset", 0...1, default: 0.25, role: .setting, modulatable: true),
            // Direction: forward is the classic phaser. Backward runs the all-pass chain through time in reverse, so each
            // transient is smeared before it arrives. Zero phase averages the two: no phase, no smear, sharper notches.
            .choice("direction", "Direction", ["forward", "backward", "zeroPhase"], default: "forward", role: .setting),
            // Retrigger: restart the sweep from Start Phase at every transient of the file, so each hit gets one clean sweep.
            .choice("retrigger", "Retrigger", ["off", "transients"], default: "off", role: .setting),
            .number("retriggerSensitivity", "Sensitivity", 0...1, default: 0.5, role: .setting,
                    shownWhen: ParameterCondition("retrigger", in: ["transients"])),
            .number("retriggerPhase", "Start Phase", 0...360, default: 270, unit: "°", role: .setting,
                    shownWhen: ParameterCondition("retrigger", in: ["transients"])),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Gain in dB times the optional `amount` input (VCA: −1…+1 mapped to 0…1; ring mod: signed).
    private static let gainVCADefinition = NodeDefinition(
        kind: .gainVCA,
        pins: [audioIn, gainAmountIn, audioOut],
        parameters: [
            .number("gain", "Gain", -60...24, default: 0, unit: "dB", modulatable: true),
            .choice("mode", "Mode", ["vca", "ringMod"], default: "vca", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    private static let utilityDefinition = NodeDefinition(
        kind: .utility,
        pins: [audioIn, audioOut],
        parameters: [
            .number("gain", "Gain", -96...48, default: 0, unit: "dB", modulatable: true),
            .number("balance", "Balance", -1...1, default: 0, modulatable: true),
            .choice("polarity", "Polarity", ["normal", "inverted"], default: "normal", role: .setting),
            .choice("monoSum", "Mono Sum", ["off", "on"], default: "off", role: .setting),
            .number("fadeIn", "Fade In", 0...600, default: 0, unit: "s", role: .setting),
            .number("fadeOut", "Fade Out", 0...600, default: 0, unit: "s", role: .setting),
            .choice("fadeCurve", "Fade Curve", ["linear", "equalPower", "smooth"], default: "linear", role: .setting),
            .choice("dcRemove", "DC Remove", ["off", "on"], default: "off", role: .setting),
            .choice("normalize", "Normalize", ["off", "peak", "rms", "loudness"], default: "off", role: .setting),
            .number("target", "Target", -70...0, default: -14, unit: "dB", role: .setting,
                    shownWhen: ParameterCondition("normalize", in: ["peak", "rms", "loudness"])),
            .number("trimStart", "Trim Start", 0...600, default: 0, unit: "s", role: .setting),
            .number("trimEnd", "Trim End", 0...600, default: 0, unit: "s", role: .setting),
            .number("padStart", "Pad Start", 0...600, default: 0, unit: "s", role: .setting),
            .number("padEnd", "Pad End", 0...600, default: 0, unit: "s", role: .setting),
        ],
        lengthRule: .adjusted("in")
    )

    /// A feedback delay line, with extra taps. Causal (it only ever reads what it has already written), so it is allowed
    /// inside a Feedback loop. Its repeats are given Tail seconds past the end of the input; the last 50 ms of that
    /// tail fade out so it never ends on a click. A tap written with an `r` ("500r") plays the last 500 ms backwards.
    /// Pitch shifts every repeat that many semitones further than the one before. Freeze stops the line taking input at
    /// Freeze Start and loops what it holds at unity until the tail ends.
    private static let delayDefinition = NodeDefinition(
        kind: .delay,
        pins: [audioIn, audioOut],
        parameters: [
            .number("time", "Time", 1...60_000, default: 250, unit: "ms", modulatable: true, scale: .exponential),
            .number("feedback", "Feedback", 0...1, default: 0.4, modulatable: true),
            .number("damping", "Damping", 200...20_000, default: 20_000, unit: "Hz", modulatable: true, scale: .exponential),
            .number("pingPong", "Ping-Pong", 0...1, default: 0),
            // Extra reads of the line: times in ms, each with an optional level in dB after an @, e.g. "375 500@-6 750@-12".
            .text("taps", "Taps", default: "", role: .macro),
            .number("pitch", "Pitch per Repeat", -24...24, default: 0, unit: "st", role: .setting),
            .choice("freeze", "Freeze", ["off", "on"], default: "off", role: .setting),
            .number("freezeStart", "Freeze Start", 0...600, default: 1, unit: "s", role: .setting,
                    shownWhen: ParameterCondition("freeze", in: ["on"])),
            .number("mix", "Mix", 0...1, default: 0.5, modulatable: true),
            .number("tail", "Tail", 0...600, default: 4, unit: "s", role: .setting),
        ],
        lengthRule: .extendedInput("in", bySeconds: "tail")
    )

    /// Convolution with an impulse response on the `ir` pin, or with the input itself when `ir` is unwired. Not causal:
    /// the whole input and impulse response are read before it renders. Length is input + impulse − 1 (`ConvolverPlan`).
    private static let convolverDefinition = NodeDefinition(
        kind: .convolver,
        pins: [
            audioIn,
            PinDefinition(id: "ir", direction: .input, signal: .audio, isRequired: false),
            audioOut,
        ],
        parameters: [
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .choice("normalize", "Normalize IR", ["on", "off"], default: "on", role: .setting),
            .number("trim", "Trim IR", 0...600, default: 0, unit: "s", role: .setting),
            .number("preDelay", "Pre-delay", 0...2_000, default: 0, unit: "ms", role: .setting),
            .number("stretch", "Stretch IR", 0.25...4, default: 1, role: .setting, scale: .exponential),
            .choice("reverse", "Reverse IR", ["off", "on"], default: "off", role: .setting),
            // Matrix: each output channel convolves with the matching channel of the impulse response (a mono one
            // serves them all). True stereo reads a four-channel impulse response: LL, LR, RL, RR.
            .choice("stereo", "Stereo", ["matrix", "trueStereo"], default: "matrix", role: .setting),
        ],
        lengthRule: .convolved("in", ir: "ir")
    )

    /// A feedback delay network of up to 256 delay lines, well past what a real-time reverb can run. Decay is the time for
    /// the loop to fall 60 dB. Loudness is held steady against Decay, Size and Damping, so Mix behaves the same everywhere.
    /// Not causal. The reverb rings on for Tail seconds past the end of the input, then fades out.
    private static let reverbDefinition = NodeDefinition(
        kind: .reverb,
        pins: [audioIn, audioOut],
        parameters: [
            .number("size", "Size", 0.1...10, default: 1, scale: .exponential),
            .number("decay", "Decay", 0.1...600, default: 3, unit: "s", scale: .exponential),
            .number("damping", "Damping", 0...1, default: 0.3),
            .number("diffusion", "Diffusion", 0...1, default: 0.7),
            .number("preDelay", "Pre-delay", 0...500, default: 0, unit: "ms"),
            .number("width", "Width", 0...2, default: 1),
            .number("mix", "Mix", 0...1, default: 0.35, modulatable: true),
            .choice("lines", "Lines", ["8", "16", "32", "64", "128", "256"], default: "64", role: .setting),
            // Twelve discrete reflections over the first 75 ms × Size, at unit energy; 0 leaves them out.
            .number("early", "Early Reflections", 0...1, default: 0, role: .setting),
            // How far (ms) each line's read point swings; the loudness and decay time stay put.
            .number("modulation", "Modulation", 0...1, default: 0, unit: "ms", role: .setting),
            // Decay time of the lows and highs as a multiple of Decay, split at Crossover.
            .number("lowDecay", "Low Decay", 0.1...4, default: 1, unit: "×", role: .setting, scale: .exponential),
            .number("highDecay", "High Decay", 0.1...4, default: 1, unit: "×", role: .setting, scale: .exponential),
            .number("crossover", "Crossover", 100...8_000, default: 800, unit: "Hz", role: .setting, scale: .exponential),
            // Freeze holds the tail at its level from Freeze Start on, ignoring all later input.
            .choice("freeze", "Freeze", ["off", "on"], default: "off", role: .setting),
            .number("freezeStart", "Freeze Start", 0...600, default: 1, unit: "s", role: .setting, shownWhen: ParameterCondition("freeze", in: ["on"])),
            .number("tail", "Tail", 0...600, default: 6, unit: "s", role: .setting),
        ],
        lengthRule: .extendedInput("in", bySeconds: "tail")
    )

    /// Compressor, expander and gate in one node, computed over the whole file: Attack is true look-ahead (the gain
    /// starts to move before the signal that causes it), and nothing is delayed. Not causal. `sidechain` drives the
    /// detector when wired. Attack and Release are the time for a gain change to settle to 90%. In expander and gate
    /// modes Attack is how early it opens and Release how it closes. Auto Makeup matches the whole file's integrated
    /// loudness (BS.1770-4) to the input's.
    private static let compressorDefinition = NodeDefinition(
        kind: .compressor,
        pins: [
            audioIn,
            PinDefinition(id: "sidechain", direction: .input, signal: .audio, isRequired: false),
            audioOut,
        ],
        parameters: [
            .choice("mode", "Mode", ["compressor", "expander", "gate"], default: "compressor", role: .setting),
            .choice("detector", "Detector", ["peak", "rms"], default: "rms", role: .setting),
            .number("rmsWindow", "RMS Window", 1...200, default: 20, unit: "ms", role: .setting, shownWhen: ParameterCondition("detector", in: ["rms"])),
            .number("threshold", "Threshold", -80...0, default: -18, unit: "dB", modulatable: true),
            .number("ratio", "Ratio", 1...100, default: 4, modulatable: true, scale: .exponential),
            .number("knee", "Knee", 0...24, default: 6, unit: "dB", role: .setting),
            .number("attack", "Attack", 0...500, default: 5, unit: "ms", role: .setting),
            .number("release", "Release", 1...5_000, default: 120, unit: "ms", role: .setting, scale: .exponential),
            .number("hold", "Hold", 0...2_000, default: 0, unit: "ms", role: .setting),
            .number("hysteresis", "Hysteresis", 0...24, default: 3, unit: "dB", role: .setting, shownWhen: ParameterCondition("mode", in: ["expander", "gate"])),
            .number("range", "Range", 0...120, default: 60, unit: "dB", role: .setting, shownWhen: ParameterCondition("mode", in: ["expander", "gate"])),
            .number("link", "Link", 0...1, default: 1, role: .setting),
            // Stereo: left/right, or mid/side (two channels only; each of mid and side gets its own curve, and Link ties them).
            .choice("stereoMode", "Stereo", ["leftRight", "midSide"], default: "leftRight", role: .setting),
            // The detector hears the sidechain (or the input) through these two filters; 0 leaves that side open.
            .number("scHighPass", "SC High-pass", 0...2_000, default: 0, unit: "Hz", role: .setting),
            .number("scLowPass", "SC Low-pass", 0...20_000, default: 0, unit: "Hz", role: .setting),
            .number("makeup", "Makeup", -24...48, default: 0, unit: "dB", modulatable: true),
            .choice("autoMakeup", "Auto Makeup", ["off", "on"], default: "off", role: .setting),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// A brickwall limiter that solves the whole file: the least gain reduction that keeps every true peak (measured by
    /// oversampling) at or under the Ceiling, which starts Look-ahead early and recovers no faster than Release allows.
    /// Not causal. A higher Oversampling holds the ceiling more tightly between samples.
    private static let limiterDefinition = NodeDefinition(
        kind: .limiter,
        pins: [audioIn, audioOut],
        parameters: [
            .number("gain", "Gain", -24...48, default: 0, unit: "dB", modulatable: true),
            .number("ceiling", "Ceiling", -24...0, default: -1, unit: "dB", role: .setting),
            .number("lookahead", "Look-ahead", 0.1...50, default: 5, unit: "ms", role: .setting, scale: .exponential),
            .number("release", "Release", 1...5_000, default: 100, unit: "ms", role: .setting, scale: .exponential),
            .choice("oversampling", "Oversampling", ["1", "2", "4", "8", "16", "32"], default: "4", role: .setting),
            .number("hold", "Hold", 0...500, default: 0, unit: "ms", role: .setting),
            .number("link", "Link", 0...1, default: 1, role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Single-sideband shift: every frequency moves by the same number of Hz, so harmonics stop being harmonic. The
    /// Hilbert transform is a long linear-phase FIR run by FFT over the whole file. Not causal. `out` is the shift
    /// (positive up, negative down) mixed with the dry signal; `up` and `down` are the pure sidebands, shifted by
    /// +|Shift| and −|Shift|, unaffected by Mix.
    private static let frequencyShifterDefinition = NodeDefinition(
        kind: .frequencyShifter,
        pins: [
            audioIn,
            audioOut,
            PinDefinition(id: "up", direction: .output, signal: .audio, isRequired: false),
            PinDefinition(id: "down", direction: .output, signal: .audio, isRequired: false),
        ],
        parameters: [
            .number("shift", "Shift", -10_000...10_000, default: 100, unit: "Hz", modulatable: true),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            // Hilbert length: standard 4,097 taps, high 32,769, maximum 262,145. Longer reaches lower into the bass.
            .choice("precision", "Precision", ["standard", "high", "maximum"], default: "high", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// OTFT Compressor (Over The Top): a compressor on every STFT bin, each with its own envelope follower and a
    /// dual-threshold gain curve: downward compression above Down Threshold, upward below Up Threshold (capped by Max
    /// Boost). Bands groups the bins on a log scale down to as few as 8. `sidechain` drives the detector when wired
    /// (spectral ducking). Not causal. Thresholds, Ratios, Max Boost, Attack and Release are read at the centre of each
    /// STFT frame. Time Tilt scales Attack and Release with frequency; the Threshold Curve ("100:-30 1000:-40 8000:-55",
    /// Hz:dB) tilts both thresholds, relative to its value at 1 kHz. Auto Makeup matches the whole file's integrated
    /// loudness to the input's (before Output Gain). Detector "anticipating" starts the gain before a loud frame.
    private static let otftCompressorDefinition = NodeDefinition(
        kind: .otftCompressor,
        pins: [
            audioIn,
            PinDefinition(id: "sidechain", direction: .input, signal: .audio, isRequired: false),
            audioOut,
        ],
        parameters: [
            .number("downThreshold", "Down Threshold", -80...0, default: -24, unit: "dB", modulatable: true),
            .number("downRatio", "Down Ratio", 1...100, default: 4, modulatable: true, scale: .exponential),
            .number("upThreshold", "Up Threshold", -90...(-10), default: -60, unit: "dB", modulatable: true),
            .number("upRatio", "Up Ratio", 1...20, default: 2, modulatable: true, scale: .exponential),
            .number("maxBoost", "Max Boost", 0...48, default: 12, unit: "dB", modulatable: true),
            .number("attack", "Attack", 0.1...500, default: 10, unit: "ms", modulatable: true, scale: .exponential),
            .number("release", "Release", 1...5_000, default: 120, unit: "ms", modulatable: true, scale: .exponential),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .number("outputGain", "Output Gain", -24...24, default: 0, unit: "dB", modulatable: true),
            .choice("fftSize", "FFT Size", ["2048", "4096", "8192", "16384", "32768", "65536"], default: "8192", role: .setting),
            .choice("overlap", "Overlap", ["75", "87.5"], default: "75", role: .setting),
            .choice("bands", "Bands", ["all", "1024", "512", "256", "128", "64", "32", "16", "8"], default: "all", role: .setting),
            .number("timeTilt", "Time Tilt", 0...1, default: 0, role: .setting),
            .number("smoothFreq", "Smooth Freq", 0...1, default: 0.3, role: .setting),
            .number("smoothTime", "Smooth Time", 0...1, default: 0.3, role: .setting),
            .number("knee", "Knee", 0...24, default: 6, unit: "dB", role: .setting),
            .choice("detector", "Detector", ["causal", "anticipating"], default: "causal", role: .setting),
            .choice("stereoLink", "Stereo Link", ["independent", "linked", "midSide"], default: "linked", role: .setting),
            .choice("autoMakeup", "Auto Makeup", ["off", "on"], default: "off", role: .setting),
            .text("thresholdCurve", "Threshold Curve", default: "", role: .macro),
            .choice("engine", "Engine", ["cpu", "gpu"], default: "cpu", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    private static let distortionDefinition = NodeDefinition(
        kind: .distortion,
        pins: [audioIn, audioOut],
        parameters: [
            .choice("mode", "Mode", ["soft", "hard"], default: "soft", modulatable: true),
            .number("drive", "Drive", 0...48, default: 6, unit: "dB", modulatable: true),
            .number("ceiling", "Ceiling", -24...0, default: 0, unit: "dB", modulatable: true),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .choice("oversampling", "Oversampling", ["1", "2", "4", "8", "16", "32", "64", "128", "256"], default: "8", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    private static let reduxDefinition = NodeDefinition(
        kind: .redux,
        pins: [audioIn, audioOut],
        parameters: [
            // Mode: classic = Bits + Rate (the shipped behaviour, the default so saved documents
            // are bit-identical); bitReduction = Bit Depth only; downsampling = anti-aliased rate
            // reduction; sampleAndHold = hold without quantising; bitwise = integer bit operation.
            .choice("reduxMode", "Mode", ["classic", "bitReduction", "downsampling", "sampleAndHold", "bitwise"], default: "classic", modulatable: true),
            // Bit Depth: used by classic, bitReduction and bitwise.
            .number("bitDepth", "Bit Depth", 1...32, default: 8, role: .macro, modulatable: true,
                    shownWhen: ParameterCondition("reduxMode", in: ["classic", "bitReduction", "bitwise"])),
            // Bit Steps: whole bits (the original) or keep the fraction of Bit Depth (3.5 bits = 2^2.5 levels).
            .choice("bitSteps", "Bit Steps", ["whole", "fractional"], default: "fractional", role: .setting,
                    shownWhen: ParameterCondition("reduxMode", in: ["classic", "bitReduction"])),
            // Rate Divider: used by classic, downsampling and sampleAndHold.
            .number("rateDivider", "Rate Divider", 1...256, default: 1, unit: "×", modulatable: true,
                    shownWhen: ParameterCondition("reduxMode", in: ["classic", "downsampling", "sampleAndHold"]), integer: true),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            // Interpolation: used by classic and downsampling.
            .choice("mode", "Interpolation", ["sampleAndHold", "linear"], default: "sampleAndHold", role: .setting,
                    shownWhen: ParameterCondition("reduxMode", in: ["classic", "downsampling"])),
            // Dither: used by the quantising modes, classic and bitReduction.
            .choice("dither", "Dither", ["off", "triangular", "shaped"], default: "off", role: .setting,
                    shownWhen: ParameterCondition("reduxMode", in: ["classic", "bitReduction"])),
            // Anti-alias: the biquad cascade (the original) or the Filters node's linear-phase FIR, with no phase shift.
            .choice("antiAlias", "Anti-alias", ["biquad", "linearPhase"], default: "linearPhase", role: .setting,
                    shownWhen: ParameterCondition("reduxMode", in: ["downsampling"])),
            // Bitwise Operator and Mask: used by bitwise only.
            .choice("bitwiseOperator", "Operator", ["and", "or", "xor"], default: "xor", role: .setting, modulatable: true,
                    shownWhen: ParameterCondition("reduxMode", in: ["bitwise"])),
            .number("mask", "Mask", 0...65_535, default: 21_845, role: .setting, modulatable: true,
                    shownWhen: ParameterCondition("reduxMode", in: ["bitwise"]), integer: true),
        ],
        lengthRule: .sameAsInput("in")
    )

    private static let waveshaperDefinition = NodeDefinition(
        kind: .waveshaper,
        pins: [audioIn, audioOut],
        parameters: [
            .choice("curve", "Curve", [
                "tanh", "arctan", "softsign", "sine", "cubic", "hardClip", "asymmetric", "chebyshev",
            ], default: "tanh", modulatable: true),
            .number("intensity", "Drive", 0...1, default: 0.5, modulatable: true),
            .number("bias", "Bias", -1...1, default: 0, modulatable: true),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            // Offline luxury: up to a 2049-tap linear-phase filter on both sides of the shaper.
            .choice("oversampling", "Oversampling", ["1", "2", "4", "8", "16", "32", "64", "128", "256"], default: "8", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    private static let wavefolderDefinition = NodeDefinition(
        kind: .wavefolder,
        pins: [audioIn, audioOut],
        parameters: [
            .choice("foldShape", "Fold Type", ["triangle", "sine"], default: "triangle", modulatable: true),
            .number("fold", "Fold", 0...1, default: 0.35, modulatable: true),
            .number("symmetry", "Symmetry", -1...1, default: 0, modulatable: true),
            .choice("stages", "Stages", ["1", "2", "3", "4", "6", "8"], default: "2"),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .number("saturation", "Saturation", 0...1, default: 0, role: .setting, modulatable: true),
            // Folding aliases brutally; offline, up to 256x with a 16,385-tap linear-phase filter tames it.
            .choice("oversampling", "Oversampling", ["1", "2", "4", "8", "16", "32", "64", "128", "256"], default: "8", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Distorts movement rather than peaks: the output chases the input with its slope and curvature
    /// soft-limited (see BakeDSP/DerivativeDistortion.h).
    private static let derivativeDistortionDefinition = NodeDefinition(
        kind: .derivativeDistortion,
        pins: [audioIn, audioOut],
        parameters: [
            // 0 dB: limiting starts at a full-scale 20 kHz sine; each +6 dB an octave lower (72 dB ≈ 5 Hz).
            .number("slopeDrive", "Slope Drive", 0...72, default: 36, unit: "dB", modulatable: true),
            // Stops at 48 dB: below a ~78 Hz curvature onset, the follower's inertia rings in the sub on kicks.
            .number("curveDrive", "Curve Drive", 0...48, default: 0, unit: "dB", modulatable: true),
            .number("edge", "Edge", -1...1, default: 0, modulatable: true),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .number("splay", "Splay", -1...1, default: 0, role: .setting, modulatable: true),
            .number("output", "Output", -24...24, default: 0, unit: "dB", role: .setting, modulatable: true),
            // The loop runs at the oversampled rate, so drives mean the same sound at every factor.
            .choice("oversampling", "Oversampling", ["1", "2", "4", "8", "16", "32", "64", "128", "256"], default: "8", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// GPU node: simplify the signal, amplify what was thrown away (see BakeGPU/ResidualExplosionKernel.swift).
    private static let residualExplosionDefinition = NodeDefinition(
        kind: .residualExplosion,
        pins: [audioIn, audioOut],
        parameters: [
            .choice("mode", "Mode", ["collapse", "sparsify"], default: "collapse", modulatable: true),
            .number("severity", "Severity", 0...1, default: 0.5, modulatable: true),
            .number("residualGain", "Residual Gain", 0...60, default: 18, unit: "dB", modulatable: true),
            .number("body", "Body", 0...1, default: 1, modulatable: true),
            .number("mix", "Mix", 0...1, default: 1, role: .setting, modulatable: true),
            // Collapse's steps and Sparsify's edges have endless harmonics; oversampled, they stop folding
            // back as fizz (the CPU nodes' filter, run on the GPU).
            .choice("oversampling", "Oversampling", ["1", "2", "4", "8", "16", "32", "64", "128", "256"], default: "8", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Octave-down synth: flip-flops on the tracked input's zero crossings (see BakeDSP/SubHarmonic.h).
    private static let subHarmonicDefinition = NodeDefinition(
        kind: .subHarmonic,
        pins: [audioIn, audioOut],
        parameters: [
            .number("sub1", "−1 Octave", 0...1, default: 0.5, modulatable: true),
            .number("sub2", "−2 Octaves", 0...1, default: 0, modulatable: true),
            .number("tone", "Tone", 40...2_000, default: 200, unit: "Hz", modulatable: true, scale: .exponential),
            .number("dry", "Dry", 0...1, default: 1, modulatable: true),
            .number("track", "Track Freq", 40...400, default: 150, unit: "Hz", role: .setting, modulatable: true, scale: .exponential),
            .number("release", "Release", 10...500, default: 60, unit: "ms", role: .setting, modulatable: true),
            // Whole file filters forward and backward (the sub lines up with the dry signal) and reads the envelope ahead (it starts on the onset).
            .choice("analysis", "Analysis", ["causal", "wholeFile"], default: "causal", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// A worn tape machine in one pass: wow, flutter, saturation, tone, hiss, dropouts (see BakeDSP/TapeDegrade.h).
    private static let tapeDegradeDefinition = NodeDefinition(
        kind: .tapeDegrade,
        pins: [audioIn, audioOut],
        parameters: [
            .number("wow", "Wow", 0...5, default: 1, unit: "ms", modulatable: true),
            .number("flutter", "Flutter", 0...0.5, default: 0.08, unit: "ms", modulatable: true),
            .number("saturation", "Saturation", 0...24, default: 6, unit: "dB", modulatable: true),
            .number("tone", "Tone", 1_000...20_000, default: 9_000, unit: "Hz", modulatable: true, scale: .exponential),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .number("wowRate", "Wow Rate", 0.1...4, default: 0.5, unit: "Hz", role: .setting, modulatable: true, scale: .exponential),
            .number("flutterRate", "Flutter Rate", 4...20, default: 9, unit: "Hz", role: .setting, modulatable: true, scale: .exponential),
            .number("hiss", "Hiss", -120...(-30), default: -90, unit: "dB", role: .setting, modulatable: true),
            .number("dropouts", "Dropouts", 0...1, default: 0, role: .setting, modulatable: true),
            .number("seed", "Seed", 0...65_535, default: 1, role: .setting, integer: true),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Two filters a Spread apart around Cutoff, swept by an internal LFO, blended by Morph (see BakeDSP/DualFilter.h).
    private static let dualFilterDefinition = NodeDefinition(
        kind: .dualFilter,
        pins: [audioIn, audioOut],
        parameters: [
            .number("cutoff", "Cutoff", 20...20_000, default: 1_000, unit: "Hz", modulatable: true, scale: .exponential),
            .number("q", "Resonance", 0.1...20, default: 0.707, modulatable: true),
            .number("bandwidth", "Spread", 0...4, default: 1, unit: "oct", modulatable: true),
            .number("morph", "Morph", 0...1, default: 0.5, modulatable: true),
            .number("lfoRate", "LFO Rate", 0.01...50, default: 0.5, unit: "Hz", modulatable: true, scale: .exponential),
            .number("lfoDepth", "LFO Depth", 0...1, default: 0, modulatable: true),
            .number("drive", "Drive", 0...24, default: 0, unit: "dB", role: .setting, modulatable: true),
            .number("mix", "Mix", 0...1, default: 1, role: .setting, modulatable: true),
            .choice("alphaType", "Alpha Type", ["lowpass", "highpass", "bandpass", "notch"], default: "lowpass", role: .setting, modulatable: true),
            .choice("betaType", "Beta Type", ["lowpass", "highpass", "bandpass", "notch"], default: "highpass", role: .setting, modulatable: true),
            .choice("lfoShape", "LFO Shape", ["sine", "triangle", "saw", "square", "sampleAndHold"], default: "sine", role: .setting, modulatable: true),
            .choice("lfoPhase", "LFO Phase", ["inverted", "inPhase"], default: "inverted", role: .setting, modulatable: true),
            .choice("slope", "Slope", ["12", "24", "48", "96", "192", "384"], default: "24", role: .setting),
            .number("seed", "Seed", 0...65_535, default: 1, role: .setting, integer: true),
            // Zero runs each path forward then backward over the whole file: no phase shift, squared magnitude.
            .choice("phase", "Phase", ["minimum", "zero"], default: "minimum", role: .setting),
            // Block updates the filters every 32 frames; per sample follows a fast LFO or modulation exactly.
            .choice("coefficients", "Coefficients", ["block", "perSample"], default: "block", role: .setting),
            // Drive's saturation at a higher rate, so it does not alias.
            .choice("oversampling", "Drive Oversampling", ["1", "2", "4", "8", "16", "32", "64", "128", "256"], default: "1", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// A clipper whose ceiling follows the signal's own envelope (see BakeDSP/AdaptiveClipping.h).
    private static let adaptiveClippingDefinition = NodeDefinition(
        kind: .adaptiveClipping,
        pins: [audioIn, audioOut],
        parameters: [
            .number("threshold", "Threshold", -24...0, default: -6, unit: "dB", modulatable: true),
            .number("release", "Release", 5...1_000, default: 100, unit: "ms", modulatable: true),
            .choice("knee", "Knee", ["hard", "soft"], default: "soft", modulatable: true),
            .number("makeup", "Makeup", 0...24, default: 0, unit: "dB", modulatable: true),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .number("floor", "Floor", -80...(-20), default: -60, unit: "dB", role: .setting, modulatable: true),
            .choice("oversampling", "Oversampling", ["1", "2", "4", "8", "16", "32", "64", "128", "256"], default: "8", role: .setting),
            // The ceiling is the highest envelope in the next Lookahead ms, so it has already risen when a transient arrives. 0 is the causal ceiling.
            .number("lookahead", "Lookahead", 0...250, default: 0, unit: "ms", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Asynchronous grains around the current position (see BakeDSP/GranularCloud.h).
    private static let granularCloudDefinition = NodeDefinition(
        kind: .granularCloud,
        pins: [audioIn, audioOut],
        parameters: [
            .number("size", "Grain Size", 5...2_000, default: 80, unit: "ms", modulatable: true, scale: .exponential),
            .number("density", "Density", 1...1_000, default: 25, unit: "/s", modulatable: true, scale: .exponential),
            .number("spray", "Spray", 0...10_000, default: 100, unit: "ms", modulatable: true),
            .number("pitchSpread", "Pitch Spread", 0...24, default: 0, unit: "st", modulatable: true),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .number("pitch", "Pitch", -24...24, default: 0, unit: "st", role: .setting, modulatable: true),
            .number("reverse", "Reverse Chance", 0...1, default: 0, role: .setting, modulatable: true),
            .number("stereoSpread", "Stereo Spread", 0...1, default: 0.5, role: .setting, modulatable: true),
            .number("seed", "Seed", 0...65_535, default: 1, role: .setting, integer: true),
            // Which range modulation of this node's controls spans: documents saved before the ranges widened keep
            // the old ones (see LegacyModulationRanges).
            .choice("modulationRange", "Modulation Range", ["current", "legacy"], default: "current", role: .hidden),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Attacks keep their first milliseconds at 1×; tails stretch to fill input × Stretch
    /// (see BakeDSP/TemporalShatter.h).
    private static let temporalShatterDefinition = NodeDefinition(
        kind: .temporalShatter,
        pins: [audioIn, audioOut],
        parameters: [
            // Changes the length, so it is fixed. 100× of a 10 s stereo file is about 380 MB.
            .number("stretch", "Stretch", 1...100, default: 4, unit: "×", taper: .power(2)),
            .number("attack", "Attack", 0.5...50, default: 5, unit: "ms", modulatable: true),
            .number("sensitivity", "Sensitivity", 0...1, default: 0.5, modulatable: true),
            .choice("mode", "Mode", ["grains", "tape"], default: "grains"),
            .number("grain", "Grain Size", 20...200, default: 80, unit: "ms", role: .setting, modulatable: true,
                    shownWhen: ParameterCondition("mode", in: ["grains"])),
        ],
        lengthRule: .scaledInput("in", by: "stretch")
    )

    /// GPU node: a bank of tuned feedback comb delay lines (see BakeGPU/ResonatorTuning.swift).
    private static let resonatorDefinition = NodeDefinition(
        kind: .resonator,
        pins: [audioIn, audioOut],
        parameters: [
            .number("root", "Root", 20...2_000, default: 110, unit: "Hz", modulatable: true),
            .number("fine", "Fine", -100...100, default: 0, unit: "ct", modulatable: true),
            .number("decay", "Decay", 0.05...30, default: 2, unit: "s", modulatable: true),
            .number("inharmonicity", "Inharmonicity", 0...1, default: 0, modulatable: true),
            .number("mix", "Mix", 0...1, default: 0.5, modulatable: true),
            .number("bands", "Bands", 64...1_024, default: 64, role: .setting, integer: true),
            .number("damping", "Damping", 0...0.99, default: 0.2, role: .setting),
            .number("saturation", "Saturation", 0...1, default: 0, role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// A folder's audio files, one per pass of a batch; each pass it is an Audio node playing one of them.
    private static let batchAudioDefinition = NodeDefinition(
        kind: .batchAudio,
        pins: [audioOut],
        parameters: [
            .number("gain", "Gain", -60...24, default: 0, unit: "dB", modulatable: true),
            .choice("formats", "Files", ["all", "wav", "matchRate"], default: "all"),
            .choice("order", "Order", ["name", "duration", "size", "random"], default: "name"),
            .number("seed", "Seed", 0...65_535, default: 1, shownWhen: ParameterCondition("order", in: ["random"]), integer: true),
            .choice("interpolation", "Interpolation", ["linear", "hermite", "sinc"], default: "sinc", role: .setting),
        ],
        lengthRule: .asset
    )

    /// One long file cut into slices (`SliceAnalysis`), one per pass of a batch; each pass it is an Audio
    /// node playing one slice's clip.
    private static let largeAudioDefinition = NodeDefinition(
        kind: .largeAudio,
        pins: [audioOut],
        parameters: [
            .number("gain", "Gain", -60...24, default: 0, unit: "dB", modulatable: true),
            .choice("sliceMode", "Slice Mode", ["transient", "musical", "seconds"], default: "transient"),
            .number("threshold", "Threshold", -80...0, default: -40, unit: "dB", shownWhen: ParameterCondition("sliceMode", in: ["transient"])),
            .number("sensitivity", "Sensitivity", 1...24, default: 6, unit: "dB", shownWhen: ParameterCondition("sliceMode", in: ["transient"])),
            .number("bpm", "BPM", 20...300, default: 120, shownWhen: ParameterCondition("sliceMode", in: ["musical"])),
            .choice("bars", "Length", ["0.25", "0.5", "1", "2", "4", "8"], default: "1", shownWhen: ParameterCondition("sliceMode", in: ["musical"])),
            .number("every", "Every", 0.05...600, default: 2, unit: "s", shownWhen: ParameterCondition("sliceMode", in: ["seconds"]), taper: .power(3)),
            .number("minLength", "Min Length", 10...10_000, default: 100, unit: "ms", taper: .power(3)),
            .number("maxLength", "Max Length", 0.1...600, default: 10, unit: "s", taper: .power(3)),
            .number("fade", "Micro-Fade", 0...5, default: 2, unit: "ms"),
            .choice("backTrack", "Back-track", ["on", "off"], default: "on", role: .setting, shownWhen: ParameterCondition("sliceMode", in: ["transient"])),
            .number("jitter", "Length Jitter", 0...100, default: 0, unit: "%", role: .setting),
            .number("seed", "Seed", 0...65_535, default: 1, role: .setting, integer: true),
            .choice("interpolation", "Interpolation", ["linear", "hermite", "sinc"], default: "sinc", role: .setting),
        ],
        lengthRule: .asset
    )

    /// Joins every pass's input end to end (`Concatenation`); its length is known only after the passes.
    /// Crossfade applies when Gap is 0.
    /// Its inputs end to end in pin order, with Gap or Crossfade (`JoinPlan`). In a batch it is also a gather:
    /// every pass's join is captured and the passes are joined in Order.
    private static let concatenateDefinition = NodeDefinition(
        kind: .concatenate,
        pins: [audioOut],
        parameters: [
            .number("gap", "Gap", 0...10_000, default: 0, unit: "ms", taper: .power(3)),
            .number("crossfade", "Crossfade", 0...1_000, default: 10, unit: "ms", taper: .power(3)),
            .choice("order", "Order", ["index", "shortest", "longest", "random"], default: "index"),
            .number("seed", "Seed", 0...65_535, default: 1, shownWhen: ParameterCondition("order", in: ["random"]), integer: true),
            .number("inputCount", "Inputs", 2...16, default: 2, role: .hidden, integer: true),
        ],
        lengthRule: .joined(gap: "gap", crossfade: "crossfade"),
        repeated: [RepeatedPins(prefix: "in", direction: .input, signal: .audio, count: .growing("inputCount", minimum: 2, maximum: 16))],
        needsAnyInput: true
    )

    /// Places every pass's clip along one stereo timeline, Total Duration long (`Scatter`).
    private static let corpusScatterDefinition: NodeDefinition = {
        let euclidean = ParameterCondition("distribution", in: ["euclidean"])
        return NodeDefinition(
            kind: .corpusScatter,
            pins: [audioIn, audioOut],
            parameters: [
                .number("duration", "Total Duration", 0.1...600, default: 10, unit: "s", taper: .power(3)),
                .choice("distribution", "Distribution", ["poisson", "uniform", "euclidean"], default: "poisson"),
                .number("density", "Density", 0.1...200, default: 8, unit: "/s", shownWhen: ParameterCondition("distribution", in: ["poisson", "uniform"]), taper: .power(3)),
                .number("timingJitter", "Timing Jitter", 0...100, default: 0, unit: "%", shownWhen: ParameterCondition("distribution", in: ["uniform"])),
                .number("steps", "Steps", 2...64, default: 16, shownWhen: euclidean, integer: true),
                .number("pulses", "Pulses", 1...64, default: 5, shownWhen: euclidean, integer: true),
                .number("step", "Step", 10...2_000, default: 125, unit: "ms", shownWhen: euclidean, taper: .power(3)),
                .choice("pick", "Pick", ["random", "inOrder"], default: "random"),
                .number("pitchJitter", "Pitch Jitter", 0...24, default: 0, unit: "st"),
                .number("panSpread", "Pan Spread", 0...100, default: 50, unit: "%"),
                .number("grainFade", "Grain Fade", 0...100, default: 5, unit: "ms", role: .setting),
                .number("level", "Level", -48...12, default: -6, unit: "dB"),
                .number("seed", "Seed", 0...65_535, default: 1, role: .setting, integer: true),
            ],
            lengthRule: .asset
        )
    }()

    /// The spectral average of every pass's clip, the median clip's length (`EnsembleAverager`).
    private static let ensembleAveragerDefinition = NodeDefinition(
        kind: .ensembleAverager,
        pins: [audioIn, audioOut],
        parameters: [
            .choice("mode", "Averaging", ["mean", "median", "geometric"], default: "mean"),
            .number("trim", "Variance Trim", 0...45, default: 0, unit: "%", shownWhen: ParameterCondition("mode", in: ["mean"])),
            .choice("align", "Align", ["start", "onset", "peak"], default: "onset"),
            .number("phaseAccuracy", "Phase Accuracy", 0...100, default: 50, unit: "%"),
            .choice("fftSize", "FFT Size", ["512", "1024", "2048", "4096", "8192", "16384"], default: "2048", role: .setting),
        ],
        lengthRule: .asset
    )

    /// Inputs A, B and C layered at their levels and aligned, the sum scaled under the Ceiling (`MatrixProcessor`).
    /// In a batch, every combination of the batches on A, B and C is one pass (`BatchRun`), which sets `combination`.
    private static let combinatorialMatrixDefinition: NodeDefinition = {
        let aligned = ParameterCondition("align", in: ["peak", "random"])
        return NodeDefinition(
            kind: .combinatorialMatrix,
            pins: ["a", "b", "c"].map { PinDefinition(id: PinID($0), direction: .input, signal: .audio, isRequired: false) } + [audioOut],
            parameters: [
                .number("levelA", "Level A", -48...12, default: 0, unit: "dB", modulatable: true),
                .number("levelB", "Level B", -48...12, default: 0, unit: "dB", modulatable: true),
                .number("levelC", "Level C", -48...12, default: 0, unit: "dB", modulatable: true),
                .choice("align", "Alignment", ["start", "peak", "random"], default: "peak"),
                .number("alignRange", "Align Range", 1...500, default: 50, unit: "ms", role: .setting, shownWhen: aligned, taper: .power(2)),
                .number("ceiling", "Ceiling", -24...0, default: -0.3, unit: "dBFS"),
                .number("seed", "Seed", 0...65_535, default: 1, role: .setting, shownWhen: ParameterCondition("align", in: ["random"]), integer: true),
                .number("combination", "Combination", 0...1_000_000, default: 0, role: .hidden, integer: true),
            ],
            lengthRule: .byChoice("align", rules: ["start": .longestInput], otherwise: .longestInputPlus(byMilliseconds: "alignRange")),
            needsAnyInput: true
        )
    }()

    /// Every output copies the input; in a batch, Mode picks which outputs each pass goes down (`BatchRun`).
    private static let forEachSplitterDefinition = NodeDefinition(
        kind: .forEachSplitter,
        pins: [audioIn],
        parameters: [
            .choice("mode", "Mode", ["broadcast", "roundRobin", "oddEven", "blocks"], default: "roundRobin"),
            .choice("outputs", "Outputs", (1...8).map(String.init), default: "2"),
        ],
        lengthRule: .sameAsInput("in"),
        repeated: [RepeatedPins(prefix: "out", direction: .output, signal: .audio, count: .parameter("outputs"))]
    )

    /// The Stretch engine at a per-pass `ratio` and `shift` (semitones), which a batch sets from each file's tempo
    /// and key (`ConformName`, or detected) and the targets. Key Offset adds on top. Outside a batch both stay 1
    /// and 0, so only Key Offset applies.
    public static let conformKeys = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let batchConformDefinition: NodeDefinition = {
        var parameters: [ParameterDefinition] = [
            .choice("conform", "Conform", ["tempoKey", "tempo", "key"], default: "tempoKey"),
        ]
        let tempo = ParameterCondition("conform", in: ["tempoKey", "tempo"])
        parameters.append(.number("targetBPM", "Target BPM", 40...300, default: 120, shownWhen: tempo))
        parameters.append(.choice("targetKey", "Target Key", conformKeys, default: "C", shownWhen: ParameterCondition("conform", in: ["tempoKey", "key"])))
        parameters.append(.number("depth", "Stretch Depth", 0...100, default: 100, unit: "%", shownWhen: tempo))
        parameters.append(.number("keyOffset", "Key Offset", -24...24, default: 0, unit: "st", modulatable: true))
        // Shift by default: preservation needs a spectral envelope, and on sparse sounds (a few pure tones) it
        // reweights the notes enough to change how a chord reads. Preserve is for voices and solo instruments.
        parameters.append(.choice("formants", "Formants", ["preserve", "shift"], default: "shift"))
        parameters.append(.choice("fftSize", "FFT Size", ["1024", "2048", "4096", "8192"], default: "4096", role: .setting))
        parameters.append(.number("ratio", "Ratio", 0.1...10, default: 1, role: .hidden))
        parameters.append(.number("shift", "Shift", -12...12, default: 0, role: .hidden))
        return NodeDefinition(kind: .batchConform, pins: [audioIn, audioOut], parameters: parameters, lengthRule: .scaledInput("in", by: "ratio"))
    }()

    /// A chunk of the input at each trigger (or each bang of its Every grid, when Trigger is unwired); in a batch,
    /// each chunk is a pass (`PhotoBoothChunks`). Otherwise it passes its input through. `capture` is set while
    /// a bake captures it: then its output carries the trigger instead.
    private static let photoBoothDefinition: NodeDefinition = {
        let notes = ["1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "ms"]
        let fixed = ParameterCondition("length", in: ["fixed"])
        var parameters: [ParameterDefinition] = [
            .choice("every", "Every", notes, default: "1/4"),
            .number("bpm", "BPM", 20...300, default: 120),
        ]
        parameters.append(.number("everyMs", "Every (ms)", 1...60_000, default: 250, unit: "ms", shownWhen: ParameterCondition("every", in: ["ms"]), taper: .power(3)))
        parameters.append(.choice("length", "Length", ["untilNext", "fixed"], default: "untilNext"))
        parameters.append(.choice("fixedLength", "Chunk Length", notes, default: "1/16", shownWhen: fixed))
        parameters.append(.number("fixedMs", "Chunk Length (ms)", 1...60_000, default: 100, unit: "ms", shownWhen: ParameterCondition("fixedLength", in: ["ms"]), taper: .power(3)))
        parameters.append(.number("fade", "Fade", 0...50, default: 2, unit: "ms", role: .setting))
        parameters.append(.number("minLength", "Min Length", 0...1_000, default: 10, unit: "ms", role: .setting))
        parameters.append(.choice("capture", "Capture", ["off", "on"], default: "off", role: .hidden))
        return NodeDefinition(
            kind: .photoBooth,
            pins: [audioIn, PinDefinition(id: "trigger", direction: .input, signal: .control, isRequired: false), audioOut],
            parameters: parameters,
            lengthRule: .sameAsInput("in")
        )
    }()

    /// Every output copies the input; in a batch, each pass is dealt to one output in its Order, Hold passes
    /// at a time (`BatchRun.merryGoRoundDeal`). The batch twin of Switch.
    private static let merryGoRoundDefinition = NodeDefinition(
        kind: .merryGoRound,
        pins: [audioIn],
        parameters: [
            .choice("outputs", "Outputs", ["2", "3", "4", "5", "6", "7", "8"], default: "3"),
            .choice("order", "Order", ["forward", "pingPong", "random", "pattern"], default: "forward"),
            .text("pattern", "Pattern", default: "1 2 3", role: .macro, shownWhen: ParameterCondition("order", in: ["pattern"])),
            .number("hold", "Hold", 1...64, default: 1, integer: true),
            .number("seed", "Seed", 0...65_535, default: 1, role: .setting, shownWhen: ParameterCondition("order", in: ["random"]), integer: true),
        ],
        lengthRule: .sameAsInput("in"),
        repeated: [RepeatedPins(prefix: "out", direction: .output, signal: .audio, count: .parameter("outputs"))]
    )

    /// Every output copies the input; in a batch, each pass goes down Low, Mid or High by its Measure (`SortMeasure`).
    private static let spectralSorterDefinition: NodeDefinition = {
        func when(_ measure: String) -> ParameterCondition { ParameterCondition("measure", in: [measure]) }
        let outputs: [PinDefinition] = ["low", "mid", "high"].map { PinDefinition(id: PinID($0), direction: .output, signal: .audio, isRequired: false) }
        var parameters: [ParameterDefinition] = [
            .choice("measure", "Measure", ["centroid", "loudness", "pitch", "decay"], default: "centroid"),
        ]
        parameters.append(.number("centroidLow", "Low Cutoff", 20...20_000, default: 150, unit: "Hz", scale: .exponential, shownWhen: when("centroid")))
        parameters.append(.number("centroidHigh", "High Cutoff", 20...20_000, default: 3_000, unit: "Hz", scale: .exponential, shownWhen: when("centroid")))
        parameters.append(.number("loudnessLow", "Low Cutoff", -90...0, default: -30, unit: "dBFS", shownWhen: when("loudness")))
        parameters.append(.number("loudnessHigh", "High Cutoff", -90...0, default: -12, unit: "dBFS", shownWhen: when("loudness")))
        parameters.append(.number("pitchLow", "Low Cutoff", 20...5_000, default: 110, unit: "Hz", scale: .exponential, shownWhen: when("pitch")))
        parameters.append(.number("pitchHigh", "High Cutoff", 20...5_000, default: 440, unit: "Hz", scale: .exponential, shownWhen: when("pitch")))
        parameters.append(.number("decayLow", "Low Cutoff", 1...20_000, default: 100, unit: "ms", shownWhen: when("decay"), taper: .power(3)))
        parameters.append(.number("decayHigh", "High Cutoff", 1...20_000, default: 500, unit: "ms", shownWhen: when("decay"), taper: .power(3)))
        parameters.append(.choice("unmeasured", "If Unmeasured", ["low", "mid", "high", "drop"], default: "drop"))
        return NodeDefinition(kind: .spectralSorter, pins: [audioIn] + outputs, parameters: parameters, lengthRule: .sameAsInput("in"))
    }()

    /// Each pass of a batch, a Bake node writing a name from its Naming: the source's (`name` with
    /// `{source}`, `{n}`; see `BatchFileName`), `name` with a number, or random words (`BatchNames`).
    private static let batchBakeDefinition = NodeDefinition(
        kind: .batchBake,
        pins: [audioIn],
        parameters: [
            .choice("naming", "Naming", ["source", "numbered", "random"], default: "source"),
            .text("name", "File Name", default: "{source}", role: .macro, shownWhen: ParameterCondition("naming", in: ["source", "numbered"])),
            .choice("digits", "Digits", ["1", "2", "3"], default: "3", shownWhen: ParameterCondition("naming", in: ["numbered"])),
            .number("seed", "Seed", 0...65_535, default: 1, shownWhen: ParameterCondition("naming", in: ["random"]), integer: true),
            .choice("bitDepth", "Bit Depth", ["16", "24", "32f"], default: "24", role: .setting),
            .choice("versions", "If the File Exists", ["newVersion", "overwrite", "skip"], default: "newVersion", role: .setting),
        ] + cleanUpParameters,
        lengthRule: .sameAsInput("in")
    )

    private static let printDefinition = NodeDefinition(
        kind: .print,
        pins: [audioIn],
        parameters: [
            .choice("bitDepth", "Bit Depth", ["16", "24", "32f"], default: "24", role: .setting),
            .choice("wavetable", "Wavetable Frames", ["off", "256", "512", "1024", "2048", "4096"], default: "off", role: .setting),
            .text("prefix", "File Name", default: "bake", role: .macro),
            .choice("versions", "If the File Exists", ["newVersion", "overwrite"], default: "newVersion", role: .setting),
        ] + cleanUpParameters,
        lengthRule: .sameAsInput("in")
    )

    /// Bake and Batch Bake's Clean Up, applied as the file is written (`CleanUp`): off by default, so
    /// a file is exactly what was rendered.
    private static let cleanUpParameters: [ParameterDefinition] = {
        let shown = ParameterCondition("cleanUp", in: ["on"])
        return [
            .choice("cleanUp", "Clean Up", ["off", "on"], default: "off", role: .setting),
            .number("noiseFloor", "Noise Floor", -120...(-20), default: -60, unit: "dB", role: .setting, shownWhen: shown),
            .number("fade", "Micro-Fade", 0...50, default: 2, unit: "ms", role: .setting, shownWhen: shown),
            .choice("dcRemoval", "Remove DC", ["off", "on"], default: "off", role: .setting, shownWhen: shown),
            .choice("normalize", "Normalize", ["off", "on"], default: "on", role: .setting, shownWhen: shown),
            .number("targetPeak", "Target Peak", -24...0, default: -0.1, unit: "dB", role: .setting, shownWhen: shown),
        ]
    }()

    /// Opens a feedback loop: `send` feeds a chain whose end is wired back into `return`, which is
    /// heard `delay` later, damped and saturated, added to `in`. `out` is the same signal, the result
    /// to bake (saved patches loop from `out`, which still works). The output rings on for `tail`.
    private static let feedbackDefinition = NodeDefinition(
        kind: .feedback,
        pins: [
            audioIn,
            PinDefinition(id: "return", direction: .input, signal: .audio, isRequired: false, isFeedbackReturn: true),
            audioOut,
            PinDefinition(id: "send", direction: .output, signal: .audio, isRequired: false),
        ],
        parameters: [
            .number("gain", "Feedback", -60...6, default: -6, unit: "dB", modulatable: true),
            // Fixed: the delay is the engine's block size for the loop.
            .number("delay", "Delay", 0...1_000, default: 10, unit: "ms", taper: .power(3)),
            .number("drive", "Drive", 0...24, default: 0, unit: "dB", modulatable: true),
            .choice("mode", "Saturation", ["tanh", "tape", "hard", "crush"], default: "tanh", modulatable: true),
            .number("lowCut", "Low Cut", 20...2_000, default: 20, unit: "Hz", role: .setting, modulatable: true, scale: .exponential),
            .number("highCut", "High Cut", 1_000...20_000, default: 12_000, unit: "Hz", role: .setting, modulatable: true, scale: .exponential),
            .number("tail", "Tail", 0...30, default: 2, unit: "s", role: .setting),
        ],
        lengthRule: .extendedInput("in", bySeconds: "tail")
    )

    /// A custom node's pins and controls come from its definition (`ProjectFile.customInterface`), and
    /// the compiler flattens it into ordinary nodes first, so this definition is never compiled.
    private static let customDefinition = NodeDefinition(kind: .custom, pins: [], parameters: [], lengthRule: .followsConsumers)

    /// Inside a definition: the custom node's inputs, one output pin per port (`boundaryPins(of:)`).
    private static let customInputDefinition = NodeDefinition(
        kind: .customInput, pins: [], parameters: [], lengthRule: .followsConsumers
    )

    /// Inside a definition: the custom node's outputs, one input pin per port (`boundaryPins(of:)`).
    private static let customOutputDefinition = NodeDefinition(
        kind: .customOutput, pins: [], parameters: [], lengthRule: .followsConsumers
    )

    /// An Inputs or Outputs card's pins: one per port, then a spare that becomes a new port when
    /// wired (`ProjectFile.connect`). Nil for every other node.
    static func boundaryPins(of node: Node) -> [PinDefinition]? {
        let direction: PinDirection
        switch node.kind {
        case .customInput: direction = .output
        case .customOutput: direction = .input
        default: return nil
        }
        let ids = (node.ports ?? []).map(\.id) + [spareBoundaryPin(of: node)]
        return ids.map { PinDefinition(id: $0, direction: direction, signal: .audio, isRequired: false) }
    }

    /// The pin an Inputs or Outputs card offers for a new port: the next unused `inN` or `outN`.
    public static func spareBoundaryPin(of node: Node) -> PinID {
        let prefix = node.kind == .customInput ? "in" : "out"
        let used = (node.ports ?? []).compactMap { CustomNodeFlattener.number(of: $0.id, prefix: prefix) }
        return "\(prefix)\((used.max() ?? 0) + 1)"
    }

    /// Sums any number of inputs; a spare input appears as you wire. Per-input gain comes later.
    private static let mixerDefinition = NodeDefinition(
        kind: .mixer,
        pins: [audioOut],
        parameters: [
            .number("gain", "Gain", -60...12, default: 0, unit: "dB", modulatable: true),
            .number("inputCount", "Inputs", 2...16, default: 2, role: .hidden, integer: true),
        ],
        lengthRule: .longestInput,
        repeated: [RepeatedPins(prefix: "in", direction: .input, signal: .audio, count: .growing("inputCount", minimum: 2, maximum: 16))],
        needsAnyInput: true
    )

    /// One mono output per channel of its input. A channel the source doesn't have is silent.
    private static let channelSplitterDefinition = NodeDefinition(
        kind: .channelSplitter,
        pins: [audioIn],
        parameters: [
            .choice("channels", "Channels", ["2", "3", "4", "5", "6", "7", "8"], default: "2"),
        ],
        lengthRule: .sameAsInput("in"),
        repeated: [RepeatedPins(
            prefix: "out", direction: .output, signal: .audio, count: .parameter("channels"),
            labels: [2: ["L", "R"]], channels: .mono
        )]
    )

    /// 2–5 bands that sum back to the input exactly (see BakeDSP/FrequencySplitter.h).
    private static let frequencySplitterDefinition = NodeDefinition(
        kind: .frequencySplitter,
        pins: [audioIn],
        parameters: [
            .choice("bands", "Bands", ["2", "3", "4", "5"], default: "3"),
            .number("split1", "Split 1", 20...20_000, default: 200, unit: "Hz", modulatable: true, scale: .exponential),
            .number("split2", "Split 2", 20...20_000, default: 2_000, unit: "Hz", modulatable: true, scale: .exponential,
                    shownWhen: ParameterCondition("bands", in: ["3", "4", "5"])),
            .number("split3", "Split 3", 20...20_000, default: 6_000, unit: "Hz", modulatable: true, scale: .exponential,
                    shownWhen: ParameterCondition("bands", in: ["4", "5"])),
            .number("split4", "Split 4", 20...20_000, default: 12_000, unit: "Hz", modulatable: true, scale: .exponential,
                    shownWhen: ParameterCondition("bands", in: ["5"])),
        ],
        lengthRule: .sameAsInput("in"),
        repeated: [RepeatedPins(
            prefix: "out", direction: .output, signal: .audio, count: .parameter("bands"),
            labels: [
                2: ["Low", "High"], 3: ["Low", "Mid", "High"], 4: ["Low", "Low Mid", "High Mid", "High"],
                5: ["Sub", "Low", "Mid", "High Mid", "High"],
            ],
            channels: .node
        )]
    )

    /// A step selector: several inputs, one output. Each bang on Advance moves to the next input (the first bang plays
    /// input 1) and Reset returns to input 1. The output is as long as the longest input and as wide as the widest; a
    /// shorter input is silent past its end, and an unwired input is a silent step.
    private static let stepSwitchDefinition = NodeDefinition(
        kind: .stepSwitch,
        pins: [
            audioOut,
            PinDefinition(id: "advance", direction: .input, signal: .control, isRequired: false),
            PinDefinition(id: "reset", direction: .input, signal: .control, isRequired: false),
        ],
        parameters: [
            .choice("inputs", "Inputs", ["2", "3", "4", "5", "6", "7", "8"], default: "4"),
            .choice("order", "Order", ["forward", "pingPong", "random", "pattern"], default: "forward"),
            .text("pattern", "Pattern", default: "1 2 3 4", role: .macro, shownWhen: ParameterCondition("order", in: ["pattern"])),
            .number("crossfade", "Crossfade", 0...50, default: 5, unit: "ms", role: .setting, modulatable: true),
            .number("seed", "Seed", 0...999_999, default: 0, role: .setting, shownWhen: ParameterCondition("order", in: ["random"]), integer: true),
        ],
        lengthRule: .longestInput,
        repeated: [RepeatedPins(prefix: "in", direction: .input, signal: .audio, count: .parameter("inputs"))],
        needsAnyInput: true
    )

    /// The Switch through schema 9 (kept so saved documents sound the same): the input plays through one output at a
    /// time, and each bang on Advance moves it on (the first bang plays step 1). Reset returns to step 1. Outputs keep
    /// the input's channels.
    private static let stepSwitchFanOutDefinition = NodeDefinition(
        kind: .stepSwitchFanOut,
        pins: [
            audioIn,
            PinDefinition(id: "advance", direction: .input, signal: .control, isRequired: false),
            PinDefinition(id: "reset", direction: .input, signal: .control, isRequired: false),
        ],
        parameters: [
            .choice("outputs", "Outputs", ["2", "3", "4", "5", "6", "7", "8"], default: "4"),
            .choice("order", "Order", ["forward", "pingPong", "random", "pattern"], default: "forward"),
            .text("pattern", "Pattern", default: "1 2 3 4", role: .macro, shownWhen: ParameterCondition("order", in: ["pattern"])),
            .number("crossfade", "Crossfade", 0...50, default: 5, unit: "ms", role: .setting, modulatable: true),
            .number("seed", "Seed", 0...999_999, default: 0, role: .setting, shownWhen: ParameterCondition("order", in: ["random"]), integer: true),
        ],
        lengthRule: .sameAsInput("in"),
        repeated: [RepeatedPins(prefix: "out", direction: .output, signal: .audio, count: .parameter("outputs"))]
    )

    /// One input per channel of its output; each input's first channel becomes one output channel.
    /// Unwired inputs are silent channels.
    private static let channelMergerDefinition = NodeDefinition(
        kind: .channelMerger,
        pins: [audioOut],
        parameters: [
            .choice("channels", "Channels", ["2", "3", "4", "5", "6", "7", "8"], default: "2"),
        ],
        lengthRule: .longestInput,
        repeated: [RepeatedPins(prefix: "in", direction: .input, signal: .audio, count: .parameter("channels"), labels: [2: ["L", "R"]])],
        channelRule: .parameter("channels"),
        needsAnyInput: true
    )

    /// Renders its input to a temporary file to listen to. No folder, no versions.
    private static let previewDefinition = NodeDefinition(
        kind: .preview,
        pins: [audioIn],
        parameters: [],
        lengthRule: .sameAsInput("in")
    )

    private static let macroDefinition: NodeDefinition = {
        var parameters: [ParameterDefinition] = [
            .number("value", "Value", 0...1, default: 0, modulatable: true),
            .text("label", "Label", default: "Macro", role: .macro),
            .choice("widget", "Control", ["dial", "slider"], default: "dial", role: .setting),
            .choice("outputs", "Outputs", (1...8).map(String.init), default: "1", role: .setting),
        ]
        for index in 1...8 {
            let shownWhen = ParameterCondition("outputs", in: Set((index...8).map(String.init)))
            parameters.append(contentsOf: [
                .number("depth\(index)", "Depth \(index)", -1...1, default: 1, role: .setting, modulatable: true, shownWhen: shownWhen),
                .number("min\(index)", "Min \(index)", 0...1, default: 0, role: .setting, modulatable: true, shownWhen: shownWhen),
                .number("max\(index)", "Max \(index)", 0...1, default: 1, role: .setting, modulatable: true, shownWhen: shownWhen),
                .choice("curve\(index)", "Curve \(index)", ["linear", "exponential", "logarithmic"], default: "linear", role: .setting, modulatable: true, shownWhen: shownWhen),
            ])
        }
        return NodeDefinition(
            kind: .macro,
            pins: [],
            parameters: parameters,
            lengthRule: .followsConsumers,
            repeated: [RepeatedPins(prefix: "out", direction: .output, signal: .control, count: .parameter("outputs"), channels: .mono)]
        )
    }()

    private static let envelopeDefinition = NodeDefinition(
        kind: .envelope,
        pins: [envelopeTriggerIn, controlOut],
        parameters: [
            // One-shot plays the whole shape per bang; Gate follows the gate; Classic is the pre-v4 behaviour.
            .choice("triggerMode", "Mode", ["oneShot", "gate", "classic"], default: "oneShot"),
            .number("attack", "Attack", 0.001...10, default: 0.01, unit: "s", modulatable: true, scale: .exponential),
            .number("decay", "Decay", 0.001...10, default: 0.1, unit: "s", modulatable: true, scale: .exponential),
            .number("sustain", "Sustain", 0...1, default: 0.7, modulatable: true),
            .number("release", "Release", 0.001...10, default: 0.3, unit: "s", modulatable: true, scale: .exponential),
            .choice("curve", "Curvature", ["linear", "exponential"], default: "exponential", role: .setting),
            .choice("loop", "Sustain Loop", ["off", "attackDecay"], default: "off", role: .setting,
                    shownWhen: ParameterCondition("triggerMode", in: ["gate", "classic"])),
            .number("timeScale", "Time Scale", 0.1...10, default: 1, role: .setting, modulatable: true, scale: .exponential),
            // With nothing on Trigger: fire every Every ms (Every), or once at the start (Once).
            .choice("repeat", "Repeat", ["every", "once"], default: "every", role: .setting),
            .number("every", "Every", 10...30_000, default: 1_000, unit: "ms", role: .setting, modulatable: true,
                    scale: .exponential, shownWhen: ParameterCondition("repeat", in: ["every"])),
        ],
        lengthRule: .followsConsumers
    )

    /// Audio-to-control follower. Reads the loudest channel and outputs a mono control trace.
    private static let envelopeFollowerDefinition = NodeDefinition(
        kind: .envelopeFollower,
        pins: [audioIn, PinDefinition(id: "out", direction: .output, signal: .control, isRequired: false, channels: .mono)],
        parameters: [
            .number("attack", "Attack", 0.1...500, default: 10, unit: "ms", modulatable: true, scale: .exponential),
            .number("release", "Release", 1...5_000, default: 100, unit: "ms", modulatable: true, scale: .exponential),
            .number("gain", "Gain", -24...24, default: 0, unit: "dB", modulatable: true),
            .choice("detection", "Detection", ["peak", "rms"], default: "peak", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Audio to a bang for every onset in the file. The whole file is analysed first, so each bang can be placed at the
    /// start of its attack (Back-track) rather than where the detector noticed it. Strength carries how hard each onset
    /// hit, 0 to 1 against the strongest in the file, held until the next onset.
    private static let transientDetectorDefinition = NodeDefinition(
        kind: .transientDetector,
        pins: [
            audioIn,
            PinDefinition(id: "out", direction: .output, signal: .control, isRequired: false, channels: .mono),
            PinDefinition(id: "strength", direction: .output, signal: .control, isRequired: false, channels: .mono),
        ],
        parameters: [
            .choice("mode", "Mode", ["energy", "spectralFlux", "highFrequency"], default: "energy", role: .setting),
            .number("sensitivity", "Sensitivity", 0...1, default: 0.5, role: .setting),
            .number("minGap", "Min Gap", 10...2_000, default: 80, unit: "ms", role: .setting, scale: .exponential),
            .number("lowCut", "Low", 20...20_000, default: 20, unit: "Hz", role: .setting, scale: .exponential),
            .number("highCut", "High", 20...20_000, default: 20_000, unit: "Hz", role: .setting, scale: .exponential),
            .number("pulseLength", "Pulse Length", 1...100, default: 5, unit: "ms", role: .setting),
            .choice("backTrack", "Back-track", ["on", "off"], default: "on", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Audio to one control: a spectral or loudness feature of the input, scaled to 0…1. Range auto maps the file's own
    /// 1st…99th percentile to 0…1; manual maps Min…Max in the feature's units (Hz for centroid, rolloff and bandwidth,
    /// LUFS for loudness, dB for crest, 0…1 for flatness and zero-crossing rate). Smooth is zero-phase, so no lag.
    private static let featureFollowerDefinition = NodeDefinition(
        kind: .featureFollower,
        pins: [
            audioIn,
            PinDefinition(id: "out", direction: .output, signal: .control, isRequired: false, channels: .mono),
        ],
        parameters: [
            .choice("feature", "Feature", ["centroid", "flatness", "flux", "rolloff", "bandwidth", "zeroCrossing", "crest", "loudness"], default: "centroid", role: .setting),
            .choice("range", "Range", ["auto", "manual"], default: "auto", role: .setting),
            .number("minimum", "Min", -100...20_000, default: 0, role: .setting, shownWhen: ParameterCondition("range", in: ["manual"])),
            .number("maximum", "Max", -100...20_000, default: 1, role: .setting, shownWhen: ParameterCondition("range", in: ["manual"])),
            .number("smooth", "Smooth", 0...2_000, default: 50, unit: "ms", role: .setting),
            .number("lowCut", "Low", 20...20_000, default: 20, unit: "Hz", role: .setting, scale: .exponential),
            .number("highCut", "High", 20...20_000, default: 20_000, unit: "Hz", role: .setting, scale: .exponential),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Audio to two controls: the pitch (YIN, windows centred on each frame, so no lag) and how
    /// sure it is (a gate). Min and Max bound the search and span the Log and Linear outputs.
    private static let pitchFollowerDefinition = NodeDefinition(
        kind: .pitchFollower,
        pins: [
            audioIn,
            PinDefinition(id: "out", direction: .output, signal: .control, isRequired: false, channels: .mono),
            PinDefinition(id: "confidence", direction: .output, signal: .control, isRequired: false, channels: .mono),
        ],
        parameters: [
            .number("minFreq", "Min Freq", 30...2_000, default: 60, unit: "Hz", modulatable: true, scale: .exponential),
            .number("maxFreq", "Max Freq", 100...4_000, default: 1_000, unit: "Hz", modulatable: true, scale: .exponential),
            .number("glide", "Glide", 0...500, default: 15, unit: "ms", modulatable: true),
            .number("threshold", "Threshold", 0...1, default: 0.6, modulatable: true),
            .choice("output", "Output", ["log", "linear", "note"], default: "log", role: .setting, modulatable: true),
            .choice("unvoiced", "When Unvoiced", ["hold", "fallToMin", "zero"], default: "hold", role: .setting, modulatable: true),
            // Median cleans each estimate against its neighbours; path picks the best route through several candidates per estimate over the whole file, so the pitch never jumps an octave.
            .choice("smoothing", "Smoothing", ["median", "path"], default: "median", role: .setting),
            // Zero phase runs Glide forward then backward over the whole file: smooth, and never behind the pitch.
            .choice("glidePhase", "Glide Phase", ["causal", "zeroPhase"], default: "causal", role: .setting),
            // Milliseconds between estimates; finer follows quick pitch changes more closely, and costs more.
            .choice("resolution", "Resolution", ["5", "2", "1", "0.5", "0.25"], default: "5", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Fires a bang on every division at its own tempo: 1 for the first Gate Length of each
    /// division, else 0, starting at frame 0. There is no project tempo; patch a Clock to what
    /// should follow it (see BakeDSP/Clock.h).
    private static let clockDefinition = NodeDefinition(
        kind: .clock,
        pins: [controlOut],
        parameters: [
            .number("bpm", "BPM", 20...300, default: 120, modulatable: true),
            .choice("division", "Division", ClockDivision.ids, default: "1/4", modulatable: true),
            .number("gateLength", "Gate Length", 1...99, default: 10, unit: "%", modulatable: true),
        ],
        lengthRule: .followsConsumers
    )

    private static let midSideEncoderDefinition = NodeDefinition(
        kind: .midSideEncoder,
        pins: [
            audioIn,
            PinDefinition(id: "mid", direction: .output, signal: .audio, isRequired: false, channels: .mono),
            PinDefinition(id: "side", direction: .output, signal: .audio, isRequired: false, channels: .mono),
        ],
        parameters: [],
        lengthRule: .sameAsInput("in")
    )

    /// Rebuilds stereo from Mid and Side: L = Mid + Side, R = Mid − Side. `mid` is required so the
    /// node always has a length; `side` is optional (a lone Mid comes out as dual mono). Inputs of
    /// different lengths or widths are read through `AudioInput`; the output is always stereo.
    private static let midSideDecoderDefinition = NodeDefinition(
        kind: .midSideDecoder,
        pins: [
            PinDefinition(id: "mid", direction: .input, signal: .audio, isRequired: true),
            PinDefinition(id: "side", direction: .input, signal: .audio, isRequired: false),
            audioOut,
        ],
        parameters: [],
        lengthRule: .longestInput,
        channelRule: .fixed(2)
    )

    /// Combines two control signals (`a`, `b`; unwired reads 0), multiplies by Scale, and holds the
    /// result between Clamp Min and Clamp Max. Divide and Modulo give 0 where `b` is (nearly) zero.
    /// Abs and Invert use `a` only.
    private static let mathDefinition = NodeDefinition(
        kind: .math,
        pins: [
            PinDefinition(id: "a", direction: .input, signal: .control, isRequired: false),
            PinDefinition(id: "b", direction: .input, signal: .control, isRequired: false),
            controlOut,
        ],
        parameters: [
            .choice("operator", "Operator", ["add", "subtract", "multiply", "divide", "abs", "invert", "modulo"], default: "add", modulatable: true),
            .number("scale", "Scale", -4...4, default: 1, modulatable: true),
            // The result is held between these; wide by default so Scale and Add can exceed ±1.
            .number("clampMin", "Clamp Min", -16...16, default: -16, role: .setting, modulatable: true),
            .number("clampMax", "Clamp Max", -16...16, default: 16, role: .setting, modulatable: true),
        ],
        lengthRule: .followsConsumers
    )

    /// Turns control signals into a gate of 0 or 1. A signal counts as high when it is above
    /// Threshold (which can be modulated). Threshold passes `a` as a gate; Not inverts it; And, Or and
    /// Xor combine `a` and `b`. Hysteresis stops a noisy signal chattering; Hold Time lengthens the
    /// gate. Unwired inputs read 0 (low).
    private static let logicDefinition = NodeDefinition(
        kind: .logic,
        pins: [
            PinDefinition(id: "a", direction: .input, signal: .control, isRequired: false),
            PinDefinition(id: "b", direction: .input, signal: .control, isRequired: false),
            controlOut,
        ],
        parameters: [
            .choice("operator", "Operator", ["threshold", "and", "or", "xor", "not"], default: "threshold", modulatable: true),
            .number("threshold", "Threshold", -1...1, default: 0.5, modulatable: true),
            // Schmitt trigger: goes high above Threshold + Hysteresis, low below Threshold − Hysteresis.
            .number("hysteresis", "Hysteresis", 0...0.5, default: 0, role: .setting, modulatable: true),
            // The gate stays high this long after it would have fallen.
            .number("holdTime", "Hold Time", 0...2, default: 0, unit: "s", role: .setting, modulatable: true),
        ],
        lengthRule: .followsConsumers
    )

    /// Snaps a control signal to the notes of a scale. The control spans ±24 semitones (±1 = ±24 st);
    /// each value moves to the nearest note of the scale built on Root (ties go down). Unwired reads 0.
    private static let quantizerDefinition = NodeDefinition(
        kind: .quantizer,
        pins: [
            PinDefinition(id: "in", direction: .input, signal: .control, isRequired: false),
            controlOut,
        ],
        parameters: [
            .choice("scale", "Scale", ["chromatic", "major", "minor", "pentatonic"], default: "chromatic", modulatable: true),
            .choice("root", "Root", (0..<12).map(String.init), default: "0", modulatable: true),
            // Slides to each new note (a one-pole glide); 0 jumps.
            .number("glide", "Glide", 0...2, default: 0, unit: "s", role: .setting, modulatable: true),
        ],
        lengthRule: .followsConsumers
    )

    /// Spectral vocoder: the modulator's loudness in each frequency band, over time, shapes the carrier.
    /// The 4096-point analysis window is fixed (the node hides it); see BakeDSP/Vocoder.h.
    private static let vocoderDefinition = NodeDefinition(
        kind: .vocoder,
        pins: [
            PinDefinition(id: "carrier", direction: .input, signal: .audio, isRequired: true),
            PinDefinition(id: "modulator", direction: .input, signal: .audio, isRequired: true),
            audioOut,
        ],
        parameters: [
            // Offline luxury: up to 256 bands, each followed with its own attack and release.
            .number("bands", "Bands", 16...256, default: 32, integer: true),
            .number("formantShift", "Formant Shift", -12...12, default: 0, unit: "st", modulatable: true),
            .number("attack", "Attack", 1...500, default: 10, unit: "ms", modulatable: true, scale: .exponential),
            .number("release", "Release", 5...2_000, default: 80, unit: "ms", modulatable: true, scale: .exponential),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .choice("spacing", "Band Spacing", ["logarithmic", "linear", "bark", "mel"], default: "logarithmic", role: .setting),
            // Adds the modulator's own high-frequency noise back, so consonants stay crisp.
            .number("sibilance", "Sibilance", 0...1, default: 0.3, role: .setting, modulatable: true),
        ],
        lengthRule: .sameAsInput("carrier")
    )

    private static let fractalFilterDefinition = NodeDefinition(
        kind: .fractalFilter,
        pins: [audioIn, audioOut],
        parameters: [
            .number("iterations", "Depth", 1...16, default: 4, modulatable: true, integer: true),
            .number("warp", "Warp", 0.1...10, default: 1, unit: "×", modulatable: true, scale: .exponential),
            .number("bias", "Mirror", -1...1, default: 0, modulatable: true),
            .number("q", "Resonance", 0.1...50, default: 1, modulatable: true, scale: .exponential),
            .number("mix", "Mix", 0...1, default: 1, modulatable: true),
            .choice("pattern", "Pattern", ["cantor", "mandelbrot", "julia", "koch"], default: "cantor", role: .setting, modulatable: true),
            .choice("phaseMode", "Phase", ["preserved", "randomized", "mirrored"], default: "preserved", role: .setting, modulatable: true),
            .choice("fftSize", "FFT Size", ["1024", "2048", "4096", "8192", "16384"], default: "4096", role: .setting),
            .number("seed", "Seed", 0...999_999, default: 1, role: .setting, integer: true),
        ],
        lengthRule: .sameAsInput("in")
    )

    /// Takes a sound apart into up to 16,384 sine partials and a noise residual, and puts it back together
    /// (see BakeDSP/Resynthesis.h). The frame size is a setting here, unlike the Vocoder: a bigger one
    /// separates close partials, a smaller one follows quick changes.
    private static let spectralResynthesisDefinition = NodeDefinition(
        kind: .spectralResynthesis,
        pins: [
            audioIn,
            // A second sound for Mode (Cross, Morph, Splice, Swap Noise); unused while Mode is Off.
            PinDefinition(id: "b", direction: .input, signal: .audio, isRequired: false),
            // While above 0.5 the sound holds the moment it froze (and fades by Decay).
            PinDefinition(id: "freeze", direction: .input, signal: .control, isRequired: false),
            audioOut,
        ],
        parameters: [
            // Offline luxury: up to 16,384 oscillators, each with its own gliding frequency and level.
            .number("partials", "Partials", 16...16_384, default: 128, integer: true),
            .number("tilt", "Tilt", -12...12, default: 0, unit: "dB/oct", modulatable: true),
            // 0 = sines only, 0.5 = the sound as analysed, 1 = residual noise only.
            .number("balance", "Sine / Noise", 0...1, default: 0.5, modulatable: true),
            // The extras rewrite the partial table (BakeDSP/Resynthesis.h). At these defaults they do
            // nothing and the original renderer runs, so documents saved before them keep their bits.
            .number("pitch", "Pitch", -24...24, default: 0, unit: "st", modulatable: true),
            .number("stretch", "Stretch", 0.25...8, default: 1, unit: "×"),
            .number("crystallize", "Crystallize", 0...1, default: 0, modulatable: true),
            .choice("mode", "Mode", ["off", "cross", "morph", "splice", "swapNoise"], default: "off"),
            .number("amount", "Amount", 0...1, default: 1, modulatable: true,
                    shownWhen: ParameterCondition("mode", in: ["cross", "morph", "splice", "swapNoise"])),
            .number("split", "Split", 100...10_000, default: 1_000, unit: "Hz", modulatable: true, scale: .exponential,
                    shownWhen: ParameterCondition("mode", in: ["splice"])),
            .choice("fftSize", "Frame Size", ["1024", "2048", "4096", "8192", "16384"], default: "4096", role: .setting),
            .number("hysteresis", "Tracking Hysteresis", 0...1, default: 0.3, role: .setting),
            .choice("harmonics", "Harmonics", ["all", "odd", "even"], default: "all", role: .setting),
            .number("quantize", "Quantize", 0...1, default: 0, role: .setting, modulatable: true),
            .choice("scale", "Scale", ["chromatic", "major", "minor", "pentatonic"], default: "chromatic", role: .setting),
            .choice("root", "Root", (0..<12).map(String.init), default: "0", role: .setting),
            .number("glide", "Glide", 0...500, default: 50, unit: "ms", role: .setting, modulatable: true),
            .number("decay", "Freeze Decay", 0...60, default: 0, unit: "dB/s", role: .setting, modulatable: true),
            .number("phaseRandomize", "Phase Randomize", 0...1, default: 0, role: .setting, modulatable: true),
            .number("seed", "Seed", 0...999_999, default: 0, role: .setting, integer: true),
            // GPU sums the sine partials on the Metal oscillator bank (floats: a few millionths off the CPU's doubles,
            // but the same for any chunk size). CPU is the original, bit-exact engine and the default.
            .choice("engine", "Engine", ["cpu", "gpu"], default: "cpu", role: .setting),
        ],
        lengthRule: .scaledInput("in", by: "stretch")
    )

    private static let chorusDefinition = NodeDefinition(
        kind: .chorus,
        pins: [audioIn, audioOut],
        parameters: [
            .number("detune", "Detune", 0...30, default: 10, unit: "ct", modulatable: true),
            .number("spread", "Spread", 0...1, default: 0.6, modulatable: true),
            .number("mix", "Mix", 0...1, default: 0.5, modulatable: true),
            // More than 8 voices (or any Reach) is the swarm: every voice reads the whole input directly.
            .choice("voices", "Voices", ["2", "4", "6", "8", "16", "32", "64", "128", "256", "512", "1024"], default: "4", role: .setting),
            .number("driftRate", "Drift Rate", 0.05...2, default: 0.3, unit: "Hz", role: .setting, modulatable: true, scale: .exponential),
            .number("panSpread", "Pan Spread", 0...1, default: 0.5, role: .setting, modulatable: true),
            // Reach: each voice's resting delay is also spread across ±Reach (scaled by Spread), including negative
            // delays that read the input's future. Pan Spread blends between one shared set of offsets and a set per channel.
            .number("reach", "Reach", 0...5_000, default: 0, unit: "ms", role: .setting),
        ],
        lengthRule: .sameAsInput("in")
    )

    private static let singleCycleDefinition = NodeDefinition(
        kind: .singleCycle,
        pins: [PinDefinition(id: "out", direction: .output, signal: .audio, isRequired: false, channels: .mono)],
        parameters: [
            // Wavetable: every cycle is exactly Frame Size samples (a table frame). Oscillator: a
            // playable source at Frequency for Length seconds. Fixed, because it sets the length.
            .choice("mode", "Mode", ["wavetable", "oscillator"], default: "wavetable"),
            .choice("shape", "Shape", ["sine", "triangle", "saw", "square", "pulse", "noise", "additive"], default: "saw", modulatable: true),
            .number("frequency", "Frequency", 20...20_000, default: 110, unit: "Hz", modulatable: true, scale: .exponential,
                    shownWhen: ParameterCondition("mode", in: ["oscillator"])),
            // Whole cycles per frame, so each frame stays seamless and the table plays N times higher.
            .number("harmonic", "Harmonic", 1...64, default: 1, modulatable: true, shownWhen: ParameterCondition("mode", in: ["wavetable"]),
                    integer: true),
                .number("width", "Pulse Width", 0.01...0.99, default: 0.5, modulatable: true,
                        shownWhen: ParameterCondition("shape", in: ["pulse"])),
                .number("phase", "Phase", 0...360, default: 0, unit: "°", modulatable: true),
                .number("warp", "Warp", -1...1, default: 0, modulatable: true),
                .number("morph", "Morph", 0...1, default: 0, modulatable: true),
                .text("partials", "Partials", default: "1 0.5 0.333 0.25", role: .setting,
                      shownWhen: ParameterCondition("shape", in: ["additive"])),
                .choice("frameSize", "Frame Size", ["256", "512", "1024", "2048", "4096"], default: "2048", role: .setting,
                        shownWhen: ParameterCondition("mode", in: ["wavetable"])),
                .number("cycles", "Cycles", 1...256, default: 1, role: .setting,
                        shownWhen: ParameterCondition("mode", in: ["wavetable"]), integer: true),
                .number("length", "Length", 0.01...600, default: 2, unit: "s", role: .setting,
                        shownWhen: ParameterCondition("mode", in: ["oscillator"])),
                .number("seed", "Seed", 0...65_535, default: 1, role: .setting,
                        shownWhen: ParameterCondition("shape", in: ["noise"]), integer: true),
        ],
        lengthRule: .byChoice(
            "mode", rules: ["oscillator": .seconds("length")], otherwise: .generated(frameSize: "frameSize", count: "cycles")
        )
    )

    private static let wavetableFactoryDefinition = NodeDefinition(
        kind: .wavetableFactory,
        pins: [audioOut],
        parameters: [
            .choice("frameSize", "Frame Size", ["256", "512", "1024", "2048", "4096"], default: "2048", role: .setting),
            // "first1024" is what patches made before this setting existed do: only their first 1,024 cycles are used.
            .choice("source", "Source", ["first1024", "whole"], default: "whole", role: .setting),
            .number("slots", "Frames", 2...256, default: 64, role: .setting, integer: true),
            .choice("morphMode", "Morph", ["linear", "spectral", "fragments"], default: "linear", role: .macro),
            .choice("snap", "Zero Snap", ["off", "on"], default: "on", role: .setting),
            .choice("dcRemoval", "DC Removal", ["off", "on"], default: "on", role: .setting),
            .choice("phaseMode", "Phases", ["keep", "align", "minimumCrest", "random"], default: "keep", role: .setting),
            .choice("normalize", "Normalize", ["off", "perFrame", "table"], default: "perFrame", role: .setting),
            .choice("fragments", "Fragments", ["4", "8", "16", "32"], default: "8", role: .setting,
                    shownWhen: ParameterCondition("morphMode", in: ["fragments"])),
            .number("seed", "Seed", 0...65_535, default: 1, role: .setting, integer: true),
            .number("inputCount", "Inputs", 2...16, default: 2, role: .hidden, integer: true),
        ],
        lengthRule: .generated(frameSize: "frameSize", count: "slots"),
        repeated: [RepeatedPins(prefix: "in", direction: .input, signal: .audio, count: .growing("inputCount", minimum: 2, maximum: 16))],
        needsAnyInput: true
    )

    /// Random control values. Unwired Trigger: a new step at Rate. Wired: each bang takes the next step (the first bang
    /// plays step 0). Steps are drawn from a hash of (Seed, step), so any chunk size gives the same signal.
    private static let randomDefinition = NodeDefinition(
        kind: .random,
        pins: [PinDefinition(id: "trigger", direction: .input, signal: .control, isRequired: false), controlOut],
        parameters: [
            .choice("mode", "Mode", ["random", "walk"], default: "random"),
            .choice("interpolation", "Interpolation", ["stepped", "linear", "cosine", "cubic"], default: "stepped"),
            .number("rate", "Rate", 0.01...2_000, default: 4, unit: "Hz", modulatable: true, scale: .exponential),
            .number("min", "Min", -1...1, default: -1, modulatable: true),
            .number("max", "Max", -1...1, default: 1, modulatable: true),
            .number("stepSize", "Step Size", 0...1, default: 0.15, shownWhen: ParameterCondition("mode", in: ["walk"])),
            .number("smooth", "Smooth", 0...5_000, default: 0, unit: "ms", modulatable: true),
            .choice("distribution", "Distribution", ["uniform", "gaussian", "coin"], default: "uniform", role: .setting,
                    shownWhen: ParameterCondition("mode", in: ["random"])),
            // With a Trigger wired, Interpolation glides over this long after each bang.
            .number("glide", "Trigger Glide", 0...5_000, default: 50, unit: "ms", role: .setting),
            .number("seed", "Seed", 0...999_999, default: 0, role: .setting, integer: true),
        ],
        lengthRule: .followsConsumers
    )

    /// Takes a sample of a signal on each bang on Trigger (or Rate times a second when it is unwired) and holds it.
    /// The signal is Signal (control) when wired, else the first channel of In (audio). Track & Hold follows the signal
    /// while the trigger is high instead of freezing it on the bang.
    private static let sampleAndHoldDefinition = NodeDefinition(
        kind: .sampleAndHold,
        pins: [
            PinDefinition(id: "in", direction: .input, signal: .audio, isRequired: false),
            PinDefinition(id: "signal", direction: .input, signal: .control, isRequired: false),
            PinDefinition(id: "trigger", direction: .input, signal: .control, isRequired: false),
            controlOut,
        ],
        parameters: [
            .choice("mode", "Mode", ["hold", "trackAndHold"], default: "hold"),
            .number("rate", "Rate", 0.01...2_000, default: 4, unit: "Hz", modulatable: true, scale: .exponential),
            .number("glide", "Glide", 0...5_000, default: 0, unit: "ms", modulatable: true),
        ],
        lengthRule: .followsConsumers
    )

    /// A source with no input: the noise colours (white, pink −3 dB/oct, brown −6, blue +3, violet +6), sparse clicks
    /// (dust: random amplitudes; velvet: ±1), an impulse train (the first impulse on frame 0) or silence. Level is the
    /// RMS for the noise colours and the peak for clicks and impulses. Each channel is its own stream. Oscillators are
    /// Single Cycle's Oscillator mode.
    private static let generatorDefinition = NodeDefinition(
        kind: .generator,
        pins: [audioOut],
        parameters: [
            .choice("type", "Type", ["white", "pink", "brown", "blue", "violet", "dust", "velvet", "impulse", "silence"], default: "white"),
            .number("level", "Level", -96...0, default: -12, unit: "dB", modulatable: true),
            .number("density", "Density", 0.1...20_000, default: 10, unit: "Hz", modulatable: true, scale: .exponential,
                    shownWhen: ParameterCondition("type", in: ["dust", "velvet", "impulse"])),
            .choice("channels", "Channels", ["1", "2"], default: "1", role: .setting),
            .number("length", "Length", 0.01...3_600, default: 5, unit: "s", role: .setting),
            .number("seed", "Seed", 0...999_999, default: 0, role: .setting,
                    shownWhen: ParameterCondition("type", in: ["white", "pink", "brown", "blue", "violet", "dust", "velvet"]), integer: true),
        ],
        lengthRule: .seconds("length"),
        channelRule: .parameter("channels")
    )

    private static let lfoDefinition = NodeDefinition(
        kind: .lfo,
        // A bang on Reset restarts the cycle at Phase: patch a Clock here to sync the LFO to it.
        pins: [PinDefinition(id: "reset", direction: .input, signal: .control, isRequired: false), controlOut],
        parameters: [
            .choice("shape", "Shape", ["sine", "triangle", "saw", "square", "sampleAndHold"], default: "sine", modulatable: true),
            .number("rate", "Rate", 0.01...100, default: 1, unit: "Hz", modulatable: true, scale: .exponential,
                    shownWhen: ParameterCondition("sync", in: ["free"])),
            // Over Length: whole cycles across everything the LFO feeds, however long that is (a 43 ms
            // wavetable cycle or a 10 min file), instead of cycles per second.
            .number("cycles", "Cycles", 0.25...256, default: 1, modulatable: true, scale: .exponential,
                    shownWhen: ParameterCondition("sync", in: ["overLength"])),
            .number("depth", "Depth", 0...1, default: 1, modulatable: true),
            .number("phase", "Phase", 0...360, default: 0, unit: "°", role: .setting, modulatable: true),
            .number("seed", "Seed", 0...999_999, default: 0, role: .setting, integer: true),
            // Clock: speed follows the gap between bangs on Reset, Cycles per Bang times per bang.
            .choice("sync", "Sync", ["free", "clock", "overLength"], default: "free", role: .setting),
            .choice("cyclesPerBang", "Cycles per Bang", ["1/4", "1/2", "1", "2", "3", "4", "8"], default: "1", role: .setting,
                    shownWhen: ParameterCondition("sync", in: ["clock"])),
        ],
        lengthRule: .followsConsumers
    )
}
