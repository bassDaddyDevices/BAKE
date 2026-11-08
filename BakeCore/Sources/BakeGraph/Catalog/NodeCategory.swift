/// The groups of the Add Node menu, in menu order. Every node kind belongs to exactly one;
/// `NodeCategoryTests` fails until a new kind is added to a list here.
public enum NodeCategory: String, CaseIterable, Sendable {
    case inOut
    /// Batch Audio, Large Audio Processor, Concatenate, Batch Bake: one render per file (`BatchRun`).
    case batch
    case effects
    case time
    case spectral
    case wavetable
    case routing
    case modulation
    /// Custom nodes and their boundary nodes. Not in the Add Node menu yet (Phase B lists saved ones).
    case custom

    /// Whether the group appears in the Add Node menu.
    public var isInAddMenu: Bool { self != .custom }

    /// The group's nodes, in menu order.
    public var kinds: [NodeKind] {
        switch self {
        case .inOut: [.audio, .generator, .preview, .print]
        case .batch: [.batchAudio, .largeAudio, .photoBooth, .concatenate, .corpusScatter, .ensembleAverager, .combinatorialMatrix, .forEachSplitter, .spectralSorter, .merryGoRound, .batchConform, .batchBake]
        case .effects: subgroups.flatMap(\.kinds)
        case .time: [.delay, .convolver, .reverb, .granularCloud, .temporalShatter, .halfTime, .beatRepeat, .looper, .stutter, .stepFX, .stretch, .reverse]
        case .spectral: [.vocoder, .spectralResynthesis, .fractalFilter, .otftCompressor]
        case .wavetable: [.singleCycle, .wavetableFactory]
        case .routing: [.mixer, .gainVCA, .utility, .stepSwitch, .channelSplitter, .channelMerger, .frequencySplitter, .midSideEncoder, .midSideDecoder, .feedback]
        case .custom: [.custom, .customInput, .customOutput]
        case .modulation: [.lfo, .random, .sampleAndHold, .macro, .envelope, .envelopeFollower, .pitchFollower, .transientDetector, .featureFollower, .clock, .math, .logic, .quantizer]
        }
    }

    /// Submenus inside the group's own submenu, in menu order; only Effects has them.
    public var subgroups: [NodeSubgroup] {
        self == .effects ? NodeSubgroup.allCases : []
    }

    /// The group whose submenu holds this one: Spectral is listed under Effects.
    public var parent: NodeCategory? {
        self == .spectral ? .effects : nil
    }

    /// Groups listed under this one, after its subgroups.
    public var children: [NodeCategory] {
        NodeCategory.allCases.filter { $0.parent == self }
    }
}

/// The parts of the Effects submenu.
public enum NodeSubgroup: String, CaseIterable, Sendable {
    case filters
    case distortion
    case dynamics
    case modulationFX

    public var kinds: [NodeKind] {
        switch self {
        case .filters: [.filters, .dualFilter, .resonator]
        case .distortion: [.distortion, .redux, .waveshaper, .wavefolder, .derivativeDistortion, .residualExplosion, .subHarmonic, .tapeDegrade, .adaptiveClipping]
        case .dynamics: [.compressor, .limiter]
        case .modulationFX: [.phaser, .flanger, .chorus, .frequencyShifter]
        }
    }
}

extension NodeKind {
    /// The Add Node group this kind is listed under.
    public var category: NodeCategory {
        NodeCategory.allCases.first { $0.kinds.contains(self) } ?? (isLegacy ? .routing : .effects)
    }

    /// The Effects submenu this kind is listed in, if it's an effect.
    public var subgroup: NodeSubgroup? {
        NodeSubgroup.allCases.first { $0.kinds.contains(self) }
    }

    /// Kinds kept only so saved documents keep sounding the same; they are not offered in the Add Node menu.
    public var isLegacy: Bool { self == .stepSwitchFanOut }
}
