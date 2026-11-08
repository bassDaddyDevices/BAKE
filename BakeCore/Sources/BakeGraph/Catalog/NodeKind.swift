/// Node types available in v1. Later waves add cases.
public enum NodeKind: String, Codable, Sendable, CaseIterable {
    case audio
    case stretch
    case reverse
    case filters
    case distortion
    case compressor
    case limiter
    case frequencyShifter
    case otftCompressor
    case flanger
    case phaser
    case redux
    case waveshaper
    case wavefolder
    case derivativeDistortion
    case residualExplosion
    case subHarmonic
    case tapeDegrade
    case dualFilter
    case adaptiveClipping
    case frequencySplitter
    case granularCloud
    case delay
    case convolver
    case reverb
    case temporalShatter
    case gainVCA
    case resonator
    case print
    case preview
    case mixer
    case channelSplitter
    case channelMerger
    case stepSwitch
    /// The Switch as it was through schema 9: one input stepped across N outputs. Saved documents are migrated
    /// onto it so they sound the same (D-019); it is no longer in the Add Node menu.
    case stepSwitchFanOut
    case feedback
    case chorus
    case lfo
    case random
    case sampleAndHold
    case generator
    case utility
    case macro
    case envelope
    case envelopeFollower
    case pitchFollower
    case transientDetector
    case featureFollower
    case clock
    case midSideEncoder
    case midSideDecoder
    case math
    case logic
    case quantizer
    case vocoder
    case spectralResynthesis
    case fractalFilter
    case halfTime
    case beatRepeat
    case looper
    case stutter
    case stepFX
    /// A saved group of nodes used as one (`Node.customDefinition` names it). Flattened before compiling.
    case custom
    /// Inside a custom node's definition: one input pin of the custom node.
    case customInput
    /// Inside a custom node's definition: one output pin of the custom node.
    case customOutput
    case singleCycle
    case wavetableFactory
    /// Plays each audio file of a folder in turn: a batch bakes the patch once per file.
    case batchAudio
    /// Writes one file per pass of a batch.
    case batchBake
    /// Large Audio Processor: cuts one long file into slices, one per pass of a batch.
    case largeAudio
    /// Joins what reaches it in every pass of a batch into one signal (a gather).
    case concatenate
    /// Scatters every pass's clip along one timeline (a gather).
    case corpusScatter
    /// The spectral average of every pass's clip (a gather).
    case ensembleAverager
    /// Layers inputs A, B and C; a batch's passes are every combination of the batches on them.
    case combinatorialMatrix
    /// Sends each pass down some of its outputs, by pass number (Broadcast, Round-Robin, Odd/Even, Blocks).
    case forEachSplitter
    /// Sends each pass down Low, Mid or High by a measure of what reaches it (`SortMeasure`).
    case spectralSorter
    /// Deals each pass to one output in an Order (Forward, Ping-Pong, Random, Pattern), Hold passes at a time.
    case merryGoRound
    /// Photo Booth: a chunk of its input at each trigger, one per pass of a batch (`PhotoBoothChunks`).
    case photoBooth
    /// Stretches and repitches each pass to a target tempo and key, from its name or what reaches it (`ConformName`).
    case batchConform

    /// Nodes that end a path: Bake writes a file, Preview renders a temporary one to listen to.
    public var isOutput: Bool { self == .print || self == .preview || self == .batchBake }

    /// Batch Audio and Batch Bake: the patch is rendered once per file (`BatchRun`).
    public var isBatch: Bool { self == .batchAudio || self == .batchBake || self == .largeAudio || self == .photoBooth || self == .batchConform || self == .combinatorialMatrix || isRouter || isGather }

    /// Gathers: what reaches them in every pass is joined into one signal after the passes (`BatchRun.afterPass`).
    public var isGather: Bool { self == .concatenate || self == .corpusScatter || self == .ensembleAverager }

    /// Routers: every output copies the input, and a batch turns some outputs off for each pass (`BatchRun.offPins`).
    public var isRouter: Bool { self == .forEachSplitter || self == .spectralSorter || self == .merryGoRound }

    /// Batch sources: they play a different file each pass (a folder's files, or a long file's slices).
    public var isBatchSource: Bool { self == .batchAudio || self == .largeAudio || self == .photoBooth }
}
