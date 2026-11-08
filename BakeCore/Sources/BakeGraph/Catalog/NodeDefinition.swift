public enum SignalType: String, Codable, Sendable {
    /// 1–N channels of audio.
    case audio
    /// One channel of modulation at the project sample rate.
    case control
}

public enum PinDirection: Sendable {
    case input
    case output
}

/// How many channels an output pin carries.
public enum OutputChannels: Hashable, Sendable {
    /// The node's own channel count.
    case node
    /// One channel (a Channel Splitter's outputs, a Mid/Side encoder's mid and side).
    case mono
}

public struct PinDefinition: Hashable, Sendable {
    public let id: PinID
    public let direction: PinDirection
    public let signal: SignalType
    /// Required inputs must be wired for the node to run.
    public let isRequired: Bool
    /// Outputs only.
    public let channels: OutputChannels
    /// A Feedback node's `return` input: the one wire allowed to close a cycle. The scheduler leaves
    /// it out of the ordering and renders the loop it closes in lockstep blocks (spec §11).
    public let isFeedbackReturn: Bool

    public init(
        id: PinID, direction: PinDirection, signal: SignalType, isRequired: Bool, channels: OutputChannels = .node,
        isFeedbackReturn: Bool = false
    ) {
        self.id = id
        self.direction = direction
        self.signal = signal
        self.isRequired = isRequired
        self.channels = channels
        self.isFeedbackReturn = isFeedbackReturn
    }
}

/// Where a parameter appears: Page 1 macro controls, or the Page 2 settings section. Hidden
/// parameters are stored (and undoable) but never drawn — e.g. a Mixer's input count.
public enum ParameterRole: Sendable {
    case macro
    case setting
    case hidden
}

/// How a modulation signal moves a parameter: linearly across its range, or in octaves (frequencies).
public enum ModulationScale: Sendable {
    case linear
    case exponential
}

public enum ParameterKind: Hashable, Sendable {
    case number(range: ClosedRange<Double>, defaultValue: Double, unit: String)
    case choice(options: [String], defaultValue: String)
    case text(defaultValue: String)
}

/// When a control appears on the card: only while another choice on the same node has one of
/// `values`. Hidden controls keep their values; they just aren't shown.
public struct ParameterCondition: Hashable, Sendable {
    public let parameter: ParameterID
    public let values: Set<String>

    public init(_ parameter: ParameterID, in values: Set<String>) {
        self.parameter = parameter
        self.values = values
    }
}

/// How a number's slider spreads its range. Automatic is linear, or logarithmic for frequencies and
/// wide positive ranges; `power(k)` puts value = min + (max − min)·position^k, giving the top of the
/// range more travel without crushing the bottom (Half Time's Speed: 1× to 0.5× is the top 29 %).
public enum SliderTaper: Hashable, Sendable {
    case automatic
    case power(Double)
}

public struct ParameterDefinition: Hashable, Sendable {
    public let id: ParameterID
    public let name: String
    public let kind: ParameterKind
    public let role: ParameterRole
    /// Whether Page 2 can tick it to spawn a modulation pin.
    public let isModulatable: Bool
    public let modulationScale: ModulationScale
    /// Shown on the card only while this holds; nil = always.
    public let shownWhen: ParameterCondition?
    /// The slider's spread. Modulation still follows `modulationScale`.
    public let taper: SliderTaper
    /// A count or an index (Steps, Bands, Bit Depth): the slider and typed values snap to whole numbers.
    /// The renderer rounds these anyway, so this only changes what the card shows.
    public let isInteger: Bool

    public init(
        id: ParameterID, name: String, kind: ParameterKind, role: ParameterRole, isModulatable: Bool,
        modulationScale: ModulationScale = .linear, shownWhen: ParameterCondition? = nil, taper: SliderTaper = .automatic,
        isInteger: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.role = role
        self.isModulatable = isModulatable
        self.modulationScale = modulationScale
        self.shownWhen = shownWhen
        self.taper = taper
        self.isInteger = isInteger
    }

    public var defaultValue: ParameterValue {
        switch kind {
        case .number(_, let value, _): .number(value)
        case .choice(_, let value): .choice(value)
        case .text(let value): .text(value)
        }
    }
}

extension ParameterDefinition {
    static func number(
        _ id: ParameterID, _ name: String, _ range: ClosedRange<Double>,
        default defaultValue: Double, unit: String = "",
        role: ParameterRole = .macro, modulatable: Bool = false, scale: ModulationScale = .linear,
        shownWhen: ParameterCondition? = nil, taper: SliderTaper = .automatic, integer: Bool = false
    ) -> Self {
        Self(id: id, name: name, kind: .number(range: range, defaultValue: defaultValue, unit: unit),
             role: role, isModulatable: modulatable, modulationScale: scale, shownWhen: shownWhen, taper: taper,
             isInteger: integer)
    }

    static func choice(
        _ id: ParameterID, _ name: String, _ options: [String],
        default defaultValue: String, role: ParameterRole = .macro, modulatable: Bool = false,
        shownWhen: ParameterCondition? = nil
    ) -> Self {
        // A modulated choice moves through its options: the renderer sees the option's index.
        Self(id: id, name: name, kind: .choice(options: options, defaultValue: defaultValue),
             role: role, isModulatable: modulatable, shownWhen: shownWhen)
    }

    static func text(
        _ id: ParameterID, _ name: String, default defaultValue: String, role: ParameterRole = .setting,
        shownWhen: ParameterCondition? = nil
    ) -> Self {
        Self(id: id, name: name, kind: .text(defaultValue: defaultValue), role: role, isModulatable: false, shownWhen: shownWhen)
    }
}

/// How many frames a node renders.
public indirect enum LengthRule: Hashable, Sendable {
    /// The node's source file, converted to the project rate, cropped, and looped.
    case asset
    /// Same as the signal on the given input.
    case sameAsInput(PinID)
    /// The given input's length times a (static) parameter.
    case scaledInput(PinID, by: ParameterID)
    /// Control generators: as long as the longest node they feed.
    case followsConsumers
    /// The longest of every wired audio input, with the most channels among them (Mixer, Merger).
    /// Inputs shorter or narrower than the node are read through `AudioInput`.
    case longestInput
    /// `longestInput` plus `milliseconds` (a static parameter): room for layers moved later (Combinatorial Matrix).
    case longestInputPlus(byMilliseconds: ParameterID)
    /// The wired audio inputs end to end in pin order, `gap` ms apart or overlapping by `crossfade` ms
    /// (`JoinPlan`), with the most channels among them (Concatenate).
    case joined(gap: ParameterID, crossfade: ParameterID)
    /// A Looper: the given input with a region repeated, laid out by `LooperPlan`.
    case looped(PinID)
    /// The given input with Trim Start/End cut from its ends and Pad Start/End of silence added around what is left,
    /// laid out by `AdjustedPlan`. A trim that leaves nothing is an invalid length.
    case adjusted(PinID)
    /// The given input plus a tail of `seconds` (a static parameter), e.g. Feedback ringing out.
    case extendedInput(PinID, bySeconds: ParameterID)
    /// The first input convolved with the second (an impulse response, or itself when that pin is unwired):
    /// input + impulse − 1 frames, the impulse as `ConvolverPlan` trims, stretches and delays it.
    case convolved(PinID, ir: PinID)
    /// A generated mono signal with `frameSize × count` frames.
    case generated(frameSize: ParameterID, count: ParameterID)
    /// A generated mono signal `seconds` (a static parameter) long.
    case seconds(ParameterID)
    /// The rule for the current option of a choice parameter (Single Cycle's Mode), else `otherwise`.
    case byChoice(ParameterID, rules: [String: LengthRule], otherwise: LengthRule)

    /// The rule that applies for these parameter values: `byChoice` resolved, anything else as is.
    public func effective(for parameters: [ParameterID: ParameterValue]) -> LengthRule {
        guard case .byChoice(let parameter, let rules, let otherwise) = self else { return self }
        if case .choice(let option)? = parameters[parameter], let rule = rules[option] {
            return rule.effective(for: parameters)
        }
        return otherwise.effective(for: parameters)
    }
}

/// Where a node's channel count comes from, after its length rule.
public enum ChannelRule: Hashable, Sendable {
    /// Whatever the length rule gave.
    case fromLength
    /// A choice parameter whose options are counts (Channel Merger).
    case parameter(ParameterID)
    case fixed(Int)
}

/// How many of a repeated pin a node has.
public enum PinCount: Hashable, Sendable {
    /// From a choice parameter whose options are counts ("2", "4", …).
    case parameter(ParameterID)
    /// One spare beyond the highest wired pin, between `minimum` and `maximum`. Stored in a hidden
    /// number parameter that the editing operations keep up to date.
    case growing(ParameterID, minimum: Int, maximum: Int)
}

/// Pins `<prefix>1 … <prefix>N`, all optional. Their IDs are saved in documents.
public struct RepeatedPins: Hashable, Sendable {
    public let prefix: String
    public let direction: PinDirection
    public let signal: SignalType
    public let count: PinCount
    /// Display names for a given count, e.g. `[2: ["L", "R"]]`; otherwise "In 1", "Out 2", ….
    public let labels: [Int: [String]]
    /// Outputs only.
    public let channels: OutputChannels

    public init(
        prefix: String, direction: PinDirection, signal: SignalType, count: PinCount,
        labels: [Int: [String]] = [:], channels: OutputChannels = .node
    ) {
        self.prefix = prefix
        self.direction = direction
        self.signal = signal
        self.count = count
        self.labels = labels
        self.channels = channels
    }

    func id(_ number: Int) -> PinID { "\(prefix)\(number)" }

    /// 1-based index of `pin` in this group, or nil.
    func number(of pin: PinID) -> Int? {
        guard pin.hasPrefix(prefix), let number = Int(pin.dropFirst(prefix.count)), number >= 1 else { return nil }
        return number
    }
}

public struct NodeDefinition: Sendable {
    public let kind: NodeKind
    public let pins: [PinDefinition]
    public let parameters: [ParameterDefinition]
    public let lengthRule: LengthRule
    /// Pins whose count comes from a setting or grows as you wire (after the fixed `pins`).
    public var repeated: [RepeatedPins] = []
    public var channelRule: ChannelRule = .fromLength
    /// At least one repeated input must be wired (repeated pins are each optional).
    public var needsAnyInput = false

    public func parameter(_ id: ParameterID) -> ParameterDefinition? {
        parameters.first { $0.id == id }
    }
}
