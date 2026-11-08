import BakeDSP
import BakeGraph

/// Builds the complete table once, then copies requested chunks to the mono output.
final class WavetableFactoryProcessor: StepProcessor {
    private let inputs: [bake.dsp.AudioInput]
    private let settings: bake.dsp.WavetableSettings
    private let sourceFrames: UnsafeMutableBufferPointer<Float>
    private let table: UnsafeMutableBufferPointer<Float>
    private let fftScratch: UnsafeMutableBufferPointer<Double>
    private let output: UnsafeMutableBufferPointer<Float>
    private var built = false

    deinit {
        sourceFrames.deallocate()
        table.deallocate()
        fftScratch.deallocate()
    }

    init(step: RenderStep, pool: BufferPool) throws {
        guard let outputBinding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        let frameSize: Int
        if case .choice(let value)? = step.parameters["frameSize"], let parsed = Int(value) { frameSize = parsed }
        else { throw RenderError.unsupportedNode(step.kind) }
        let slots = Int((step.parameters["slots"]?.numberValue ?? 64).rounded())
        let inputCount = min(max(Int((step.parameters["inputCount"]?.numberValue ?? 2).rounded()), 2), 16)
        var settings = bake.dsp.WavetableSettings()
        settings.frameSize = frameSize
        settings.slots = slots
        settings.fragments = Int(Self.choice("fragments", step: step, fallback: "8")) ?? 8
        settings.seed = UInt64(max((step.parameters["seed"]?.numberValue ?? 1).rounded(), 0))
        settings.morph = Self.morph(Self.choice("morphMode", step: step, fallback: "linear"))
        settings.phase = Self.phase(Self.choice("phaseMode", step: step, fallback: "keep"))
        settings.normalize = Self.normalize(Self.choice("normalize", step: step, fallback: "perFrame"))
        settings.snap = Self.toggle(Self.choice("snap", step: step, fallback: "on"))
        settings.dcRemoval = Self.toggle(Self.choice("dcRemoval", step: step, fallback: "on"))
        let sources = (1...inputCount).map { bake.dsp.AudioInput("in\($0)", of: step, pool: pool) }
        // Older patches keep only their first 1,024 cycles; "whole" fits every input cycle (the audio is already in memory).
        var capacity = Int(bake.dsp.wavetableMaxSourceFrames)
        if Self.choice("source", step: step, fallback: "first1024") == "whole" {
            let needed = sources.reduce(0) { $0 + (Int($1.frames) + frameSize - 1) / frameSize }
            capacity = max(needed, 1)
        }
        settings.maxSourceFrames = capacity
        self.settings = settings
        inputs = sources
        sourceFrames = .allocate(capacity: capacity * frameSize)
        table = .allocate(capacity: frameSize * slots)
        table.initialize(repeating: 0)
        fftScratch = .allocate(capacity: Int(bake.dsp.wavetableFFTWorkspaceDoubles(frameSize)))
        output = pool.channel(0, of: outputBinding)
    }

    private static func choice(_ id: String, step: RenderStep, fallback: String) -> String {
        if case .choice(let choice)? = step.parameters[id] { return choice }
        return fallback
    }

    private static func morph(_ value: String) -> bake.dsp.WavetableMorph {
        switch value {
        case "spectral": .spectral
        case "fragments": .fragments
        default: .linear
        }
    }

    private static func phase(_ value: String) -> bake.dsp.WavetablePhase {
        switch value {
        case "align": .align
        case "minimumCrest": .minimumCrest
        case "random": .random
        default: .keep
        }
    }

    private static func normalize(_ value: String) -> bake.dsp.WavetableNormalize {
        switch value {
        case "perFrame": .perFrame
        case "table": .table
        default: .off
        }
    }

    private static func toggle(_ value: String) -> bake.dsp.WavetableToggle {
        value == "on" ? .on : .off
    }

    func process(frames: Range<Int>) async throws {
        if !built {
            inputs.withUnsafeBufferPointer { inputPointer in
                bake.dsp.buildWavetable(settings, inputPointer.baseAddress, inputPointer.count,
                                        sourceFrames.baseAddress, sourceFrames.count,
                                        table.baseAddress, fftScratch.baseAddress)
            }
            built = true
        }
        guard let destination = output.baseAddress, let source = table.baseAddress else { return }
        destination.advanced(by: frames.lowerBound).update(from: source.advanced(by: frames.lowerBound), count: frames.count)
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
