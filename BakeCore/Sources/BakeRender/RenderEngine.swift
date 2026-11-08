import BakeGPU
import BakeGraph
import Foundation

public struct RenderRequest: Sendable {
    public var plan: RenderPlan
    /// Resolved, readable URLs for every asset the plan uses. The app resolves bookmarks (M5).
    public var assetURLs: [AssetID: URL]
    /// Folder Bake (Print) nodes write into unless they have their own.
    public var outputDirectory: URL
    /// Per-Bake-node folders; nodes not listed write to `outputDirectory`.
    public var outputDirectories: [NodeID: URL]
    /// Frames per processing chunk. Progress and cancellation are checked between chunks.
    public var chunkFrames: Int
    /// Also summarise what every node produced (waveform and spectrogram) for the cards. Costs one
    /// pass over each output, no extra rendering.
    public var collectSummaries: Bool
    /// The whole patch, written into every Bake node's WAV so dropping it on the canvas reopens it.
    /// Nil writes plain WAVs.
    public var workflow: ProjectFile?

    public init(
        plan: RenderPlan, assetURLs: [AssetID: URL], outputDirectory: URL,
        outputDirectories: [NodeID: URL] = [:], chunkFrames: Int = 65_536, collectSummaries: Bool = false,
        workflow: ProjectFile? = nil
    ) {
        self.plan = plan
        self.assetURLs = assetURLs
        self.outputDirectory = outputDirectory
        self.outputDirectories = outputDirectories
        self.chunkFrames = max(chunkFrames, 1)
        self.collectSummaries = collectSummaries
        self.workflow = workflow
    }
}

public struct RenderProgress: Equatable, Sendable {
    /// 0…1 across all steps, weighted by frames.
    public let fraction: Double
    public let stepIndex: Int
    public let stepCount: Int
}

public struct RenderResult: Equatable, Sendable {
    /// Final file for each Print node.
    public let outputs: [NodeID: URL]
    /// What each node's output pins produced, when the request asked for it.
    public let summaries: [PinRef: NodeSummary]

    init(outputs: [NodeID: URL], summaries: [PinRef: NodeSummary] = [:]) {
        self.outputs = outputs
        self.summaries = summaries
    }
}

/// Runs a compiled plan offline on BAKE's two DSP engines.
public enum RenderEngine {
    /// The GPU engine, created once per app run so its pipelines compile only once.
    private static let gpu = Result { () throws(GPUError) in try GPUContext() }

    /// Renders off the caller's actor. Output files appear only if every step succeeds;
    /// on error or cancellation nothing is left in the output folder.
    @concurrent
    public static func render(
        _ request: RenderRequest,
        progress: @Sendable (RenderProgress) -> Void = { _ in }
    ) async throws -> RenderResult {
        let plan = request.plan
        try checkSupported(request)
        let memoryBudget = Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.75)
        guard plan.peakMemoryBytes <= memoryBudget else {
            throw RenderError.insufficientMemory(requiredBytes: plan.peakMemoryBytes)
        }

        let context: GPUContext
        do {
            context = try gpu.get()
        } catch {
            throw RenderError.gpuUnavailable
        }
        let pool: BufferPool
        do {
            pool = try BufferPool(capacities: plan.bufferCapacities, gpu: context)
        } catch .allocationFailed {
            throw RenderError.insufficientMemory(requiredBytes: plan.peakMemoryBytes)
        } catch {
            throw RenderError.gpuUnavailable
        }

        let destinations = outputURLs(for: plan, request: request)
        let totalFrames = max(plan.steps.reduce(0) { $0 + $1.shape.frames }, 1)
        var renderedFrames = 0
        var pending: [PendingOutput] = []
        var summaries: [PinRef: NodeSummary] = [:]
        var active: [any StepProcessor] = []

        do {
            var index = 0
            while index < plan.steps.count {
                // A feedback loop's steps run together, one block of at most its delay at a time; any
                // other step is a loop of one, run in chunks.
                let loop = plan.loops.first { $0.steps.lowerBound == index }
                let range = loop?.steps ?? index..<(index + 1)
                let block = min(loop?.blockFrames ?? request.chunkFrames, request.chunkFrames)
                let frames = plan.steps[index].shape.frames
                for member in range {
                    active.append(try makeProcessor(
                        for: plan.steps[member], request: request, destinations: destinations, pool: pool, gpu: context
                    ))
                }
                var start = 0
                var sinceYield = 0
                while start < frames {
                    try Task.checkCancellation()
                    let end = min(start + block, frames)
                    for (offset, processor) in active.enumerated() {
                        try await processor.process(frames: start..<end)
                        renderedFrames += end - start
                        if loop == nil || sinceYield >= request.chunkFrames {
                            progress(RenderProgress(
                                fraction: Double(renderedFrames) / Double(totalFrames),
                                stepIndex: range.lowerBound + offset,
                                stepCount: plan.steps.count
                            ))
                        }
                    }
                    sinceYield += end - start
                    start = end
                    // Loops with a short delay run many small blocks: yield once per chunk's worth.
                    if loop == nil || sinceYield >= request.chunkFrames {
                        sinceYield = 0
                        await Task.yield()
                    }
                }
                for (member, processor) in zip(range, active) {
                    let step = plan.steps[member]
                    if request.collectSummaries {
                        for (pin, binding) in step.outputs {
                            summaries[PinRef(node: step.node, pin: pin)] = NodeAnalyzer.summarize(
                                binding, isControl: NodeAnalyzer.isControl(pin, of: step.kind),
                                sampleRate: plan.sampleRate, pool: pool
                            )
                        }
                    }
                    if let output = try processor.finish() {
                        pending.append(output)
                    }
                }
                active = []
                index = range.upperBound
            }
            try Task.checkCancellation()
            return try commit(pending, destinations: destinations, summaries: summaries)
        } catch {
            for processor in active { processor.discard() }
            for output in pending {
                try? FileManager.default.removeItem(at: output.temporaryURL)
            }
            throw error
        }
    }

    // MARK: - Helpers

    /// Rejects work the engine can't do, before any buffer or file is created. Every v1 kind
    /// renders; new kinds join `makeProcessor`'s exhaustive switch.
    private static func checkSupported(_ request: RenderRequest) throws {
        for step in request.plan.steps {
            if step.kind == .audio, let assetID = step.assetID, request.assetURLs[assetID] == nil {
                throw RenderError.missingAssetURL(assetID)
            }
        }
    }

    private static func makeProcessor(
        for step: RenderStep, request: RenderRequest, destinations: [NodeID: URL], pool: BufferPool, gpu: GPUContext
    ) throws -> any StepProcessor {
        switch step.kind {
        case .audio:
            guard let assetID = step.assetID, let url = request.assetURLs[assetID] else {
                throw RenderError.unsupportedNode(step.kind)
            }
            return try AudioSourceProcessor(step: step, url: url, sampleRate: request.plan.sampleRate, pool: pool)
        case .batchAudio, .batchBake, .largeAudio, .corpusScatter, .ensembleAverager:
            // A batch renders its passes, each with these turned into Audio and Bake (`BatchRun.pass`).
            throw RenderError.unsupportedNode(step.kind)
        case .print, .preview:
            guard let url = destinations[step.node] else { throw RenderError.unsupportedNode(step.kind) }
            return try PrintProcessor(
                step: step, finalURL: url, sampleRate: request.plan.sampleRate,
                maxChunkFrames: request.chunkFrames, pool: pool,
                workflow: step.kind == .print ? request.workflow.map { BakedWorkflow(bakeNode: step.node, project: $0) } : nil
            )
        case .resonator:
            return try ResonatorProcessor(step: step, sampleRate: request.plan.sampleRate, gpu: gpu, pool: pool)
        case .residualExplosion:
            return try ResidualExplosionProcessor(step: step, gpu: gpu, pool: pool)
        case .lfo:
            return try LFOProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .utility:
            return try UtilityProcessor(
                step: step, sampleRate: request.plan.sampleRate, maxChunkFrames: request.chunkFrames, pool: pool
            )
        case .frequencyShifter:
            return try FrequencyShifterProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .limiter:
            return try LimiterProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .compressor:
            return try CompressorProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .reverb:
            return try ReverbProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .convolver:
            return try ConvolverProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .delay:
            return try DelayProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .generator:
            return try GeneratorProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .sampleAndHold:
            return try SampleAndHoldProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .random:
            return try RandomProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .macro:
            return try MacroProcessor(step: step, pool: pool)
        case .singleCycle:
            return try SingleCycleProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .wavetableFactory:
            return try WavetableFactoryProcessor(step: step, pool: pool)
        case .feedback:
            return try FeedbackProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .custom, .customInput, .customOutput:
            // Flattened away before compiling; never in a plan.
            throw RenderError.unsupportedNode(step.kind)
        case .stepSwitch:
            return try SwitchMixProcessor(step: step, sampleRate: request.plan.sampleRate, maxChunkFrames: request.chunkFrames, pool: pool)
        case .stepSwitchFanOut:
            return try SwitchProcessor(step: step, sampleRate: request.plan.sampleRate, maxChunkFrames: request.chunkFrames, pool: pool)
        case .clock:
            return try ClockProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .envelope:
            return try EnvelopeProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .envelopeFollower:
            return try EnvelopeFollowerProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .transientDetector:
            return try TransientDetectorProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .featureFollower:
            return try FeatureFollowerProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .pitchFollower:
            return try PitchFollowerProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .chorus:
            return try ChorusProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool, maxChunkFrames: request.chunkFrames)
        case .filters:
            return try FiltersProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .distortion:
            return try DistortionProcessor(step: step, pool: pool, maxChunkFrames: request.chunkFrames)
        case .flanger:
            return try FlangerProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .phaser:
            return try PhaserProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool, maxChunkFrames: request.chunkFrames)
        case .redux:
            return try ReduxProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool, maxChunkFrames: request.chunkFrames)
        case .derivativeDistortion:
            return try DerivativeDistortionProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool, maxChunkFrames: request.chunkFrames)
        case .subHarmonic:
            return try SubHarmonicProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool, maxChunkFrames: request.chunkFrames)
        case .tapeDegrade:
            return try TapeDegradeProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .dualFilter:
            return try DualFilterProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool, maxChunkFrames: request.chunkFrames)
        case .adaptiveClipping:
            return try AdaptiveClippingProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool, maxChunkFrames: request.chunkFrames)
        case .frequencySplitter:
            return try FrequencySplitterProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .granularCloud:
            return try GranularCloudProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool, maxChunkFrames: request.chunkFrames)
        case .temporalShatter:
            return try TemporalShatterProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .waveshaper:
            return try WaveshaperProcessor(step: step, pool: pool, maxChunkFrames: request.chunkFrames)
        case .wavefolder:
            return try WavefolderProcessor(step: step, pool: pool, maxChunkFrames: request.chunkFrames)
        case .gainVCA:
            return try GainVCAProcessor(step: step, pool: pool)
        case .stretch:
            return try StretchProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .channelSplitter:
            return try ChannelSplitterProcessor(step: step, pool: pool)
        case .channelMerger:
            return try ChannelMergerProcessor(step: step, pool: pool)
        case .mixer:
            return try MixerProcessor(step: step, pool: pool)
        case .concatenate:
            return try ConcatenateProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .batchConform:
            return try ConformProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .photoBooth:
            return try PhotoBoothProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .forEachSplitter, .spectralSorter, .merryGoRound:
            return try RouterProcessor(step: step, pool: pool)
        case .combinatorialMatrix:
            return try MatrixProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .reverse:
            return try ReverseProcessor(step: step, pool: pool)
        case .stepFX:
            return try StepFXProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .stutter:
            return try StutterProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .looper:
            return try LooperProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .beatRepeat:
            return try BeatRepeatProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .halfTime:
            return try HalfTimeProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .midSideEncoder:
            return try MidSideEncoderProcessor(step: step, pool: pool)
        case .midSideDecoder:
            return try MidSideDecoderProcessor(step: step, pool: pool)
        case .math:
            return try MathProcessor(step: step, pool: pool)
        case .logic:
            return try LogicProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .quantizer:
            return try QuantizerProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool)
        case .spectralResynthesis:
            return try ResynthesisProcessor(step: step, sampleRate: request.plan.sampleRate, gpu: gpu, pool: pool, maxChunkFrames: request.chunkFrames)
        case .vocoder:
            return try VocoderProcessor(step: step, sampleRate: request.plan.sampleRate, pool: pool, maxChunkFrames: request.chunkFrames)
        case .otftCompressor:
            return try OtftCompressorProcessor(step: step, sampleRate: request.plan.sampleRate, gpu: gpu, pool: pool, maxChunkFrames: request.chunkFrames)
        case .fractalFilter:
            return try FractalFilterProcessor(step: step, sampleRate: request.plan.sampleRate, gpu: gpu, pool: pool, maxChunkFrames: request.chunkFrames)
        }
    }

    /// Each Bake node writes `<file name>.wav` into its folder. With "newVersion" (the default), an
    /// existing file is kept and the next free `<name>-2.wav`, `-3`, … is used; two nodes in one bake
    /// never share a name. A Preview node writes `preview-<node id>.wav`, replacing its last render.
    static func outputURLs(for plan: RenderPlan, request: RenderRequest) -> [NodeID: URL] {
        var urls: [NodeID: URL] = [:]
        var taken: Set<String> = []
        for step in plan.steps where step.kind.isOutput {
            let folder = request.outputDirectories[step.node] ?? request.outputDirectory
            // Previews are scratch files: one per node, always replaced.
            let isPreview = step.kind == .preview
            let name = isPreview ? "preview-\(step.node.rawValue.uuidString)" : bakeFileName(step.parameters["prefix"])
            let keepExisting = !isPreview && step.parameters["versions"] != .choice("overwrite")
            var candidate = folder.appendingPathComponent(name).appendingPathExtension("wav")
            var version = 1
            while taken.contains(candidate.path) || (keepExisting && FileManager.default.fileExists(atPath: candidate.path)) {
                version += 1
                candidate = folder.appendingPathComponent("\(name)-\(version)").appendingPathExtension("wav")
            }
            taken.insert(candidate.path)
            urls[step.node] = candidate
        }
        return urls
    }

    /// A Bake node's file name without `.wav`, from its File Name: `/ : \\` become `_`; empty is "bake".
    public static func bakeFileName(_ value: ParameterValue?) -> String {
        guard case .text(let text)? = value else { return "bake" }
        let cleaned = String(text.map { "/:\\".contains($0) ? "_" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "bake" : cleaned
    }

    /// Moves finished temporaries into place, replacing existing files.
    private static func commit(
        _ pending: [PendingOutput], destinations: [NodeID: URL], summaries: [PinRef: NodeSummary]
    ) throws -> RenderResult {
        let fileManager = FileManager.default
        for output in pending {
            do {
                if fileManager.fileExists(atPath: output.finalURL.path) {
                    _ = try fileManager.replaceItemAt(output.finalURL, withItemAt: output.temporaryURL)
                } else {
                    try fileManager.moveItem(at: output.temporaryURL, to: output.finalURL)
                }
            } catch {
                throw RenderError.writeFailed(output.finalURL)
            }
        }
        return RenderResult(outputs: destinations, summaries: summaries)
    }
}
