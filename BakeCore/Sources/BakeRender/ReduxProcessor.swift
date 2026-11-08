import BakeDSP
import BakeGraph
import Foundation

/// Redux node on the CPU engine. Each channel carries its own bit/rate/dither state, so channels run in
/// parallel with identical bits on any core count.
///
/// Downsampling can use the Filters node's linear-phase FIR as its anti-alias: it reads the whole channel
/// (no delay, no phase shift), is filtered a chunk at a time into per-channel scratch, and is handed to the kernel.
final class ReduxProcessor: StepProcessor {
    private let algorithm: bake.dsp.ReduxAlgorithm
    private let mode: bake.dsp.ReduxMode
    private let dither: bake.dsp.ReduxDither
    private let bitwiseOp: bake.dsp.ReduxBitwiseOp
    private let mask: Int32
    private let modulation: bake.dsp.ReduxModulation
    private let bitDepth: bake.dsp.ParameterSignal
    private let rateDivider: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let channelState: ChannelStates<bake.dsp.ReduxState>
    private let workers: Int
    private let fractionalBits: Bool
    private let usesLinearPhase: Bool
    /// Set up on the first chunk, once the upstream modulation exists.
    private var filter: LinearPhaseAntiAlias?

    init(
        step: RenderStep, sampleRate: Double, pool: BufferPool,
        maxChunkFrames: Int = 65_536, workers: Int = Parallel.coreCount
    ) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        // Mode (reduxMode) is what the node does; Interpolation (mode) is how S&H/linear holds.
        var algorithmName = "classic"
        if case .choice(let value)? = step.parameters["reduxMode"] { algorithmName = value }
        algorithm = switch algorithmName {
        case "bitReduction": .bitReduction
        case "downsampling": .downsampling
        case "sampleAndHold": .sampleAndHold
        case "bitwise": .bitwise
        default: .classic
        }
        var modeName = "sampleAndHold"
        if case .choice(let value)? = step.parameters["mode"] { modeName = value }
        mode = modeName == "linear" ? .linear : .sampleAndHold
        var ditherName = "off"
        if case .choice(let value)? = step.parameters["dither"] { ditherName = value }
        dither = switch ditherName {
        case "triangular": .triangular
        case "shaped": .shaped
        default: .off
        }
        var bitwiseName = "xor"
        if case .choice(let value)? = step.parameters["bitwiseOperator"] { bitwiseName = value }
        bitwiseOp = switch bitwiseName {
        case "and": .bitAnd
        case "or": .bitOr
        default: .bitXor
        }
        mask = Int32(step.parameters["mask"]?.numberValue ?? 21_845)
        var modulation = bake.dsp.ReduxModulation()
        modulation.algorithm = bake.dsp.ParameterSignal("reduxMode", of: step, pool: pool)
        modulation.bitwiseOp = bake.dsp.ParameterSignal("bitwiseOperator", of: step, pool: pool)
        modulation.mask = bake.dsp.ParameterSignal("mask", of: step, pool: pool)
        self.modulation = modulation
        bitDepth = bake.dsp.ParameterSignal("bitDepth", of: step, pool: pool)
        rateDivider = bake.dsp.ParameterSignal("rateDivider", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        self.sampleRate = sampleRate
        // The settings added after release. Saved documents are migrated to the old values
        // (ProjectMigration), so these fallbacks only matter for a step built without them.
        var bitStepsName = "whole"
        if case .choice(let value)? = step.parameters["bitSteps"] { bitStepsName = value }
        fractionalBits = bitStepsName == "fractional"
        var antiAliasName = "biquad"
        if case .choice(let value)? = step.parameters["antiAlias"] { antiAliasName = value }
        usesLinearPhase = antiAliasName == "linearPhase"
            && (algorithm == .downsampling || modulation.algorithm.modulation != nil)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        self.workers = max(workers, 1)
        channelState = ChannelStates(
            channels: output.shape.channels, initial: bake.dsp.ReduxState(), historyFloats: 0,
            scratchFloats: usesLinearPhase ? maxChunkFrames : 1
        )
    }

    func process(frames: Range<Int>) async throws {
        if usesLinearPhase, filter == nil {
            filter = LinearPhaseAntiAlias(
                rateDivider: rateDivider, frames: inputs.first?.count ?? 0, channels: outputs.count, sampleRate: sampleRate
            )
        }
        var options = bake.dsp.ReduxOptions()
        options.fractionalBits = fractionalBits
        let filter = filter
        Parallel.forEach(outputs.count, workers: workers) { channel in
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
            var options = options
            if let filter {
                let filtered = channelState.scratch[channel]
                filter.render(channel: channel, input: source, inputFrames: inputs[channel].count, into: filtered, frames: frames)
                options.antiAliased = UnsafePointer(filtered)
            }
            bake.dsp.renderRedux(
                &channelState.states[channel], algorithm, mode, dither, bitwiseOp, mask, modulation,
                bitDepth, rateDivider, mix,
                source + frames.lowerBound, destination + frames.lowerBound,
                frames.lowerBound, frames.count, channel, sampleRate, options
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}

/// The Filters node's linear-phase low-pass, cut at the new Nyquist (sample rate / 2 / Rate Divider).
/// Immutable after init apart from its scratch, which is one block per channel, so channels never share it.
private final class LinearPhaseAntiAlias: @unchecked Sendable {
    private let taps: Int32
    private let sampleRate: Double
    private let cutoff: bake.dsp.ParameterSignal
    /// Cutoff in Hz for every frame, only when Rate Divider moves.
    private let cutoffs: UnsafeMutablePointer<Float>?
    private let scratch: [UnsafeMutablePointer<Double>]

    init(rateDivider: bake.dsp.ParameterSignal, frames: Int, channels: Int, sampleRate: Double) {
        self.sampleRate = sampleRate
        func hz(_ divider: Float) -> Double {
            let interval = min(max(Int(divider.rounded()), 1), 256)
            return min(max(sampleRate * 0.5 / Double(interval), 10), sampleRate * 0.45)
        }
        var signal = bake.dsp.ParameterSignal()
        var lowest = hz(rateDivider.valueAt(0))
        let moves = rateDivider.modulation != nil
        if moves {
            let values = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
            lowest = sampleRate
            for frame in 0..<frames {
                let cutoffHz = hz(rateDivider.valueAt(frame))
                lowest = min(lowest, cutoffHz)
                values[frame] = Float(cutoffHz / sampleRate)
            }
            // value = base + trim * modulation * (maximum - minimum) = Hz.
            signal.base = 0
            signal.minimum = 0
            signal.maximum = Float(sampleRate)
            signal.trim = 1
            signal.modulation = UnsafePointer(values)
            signal.modulationFrames = frames
            cutoffs = values
        } else {
            signal.base = Float(lowest)
            signal.minimum = 0
            signal.maximum = Float(sampleRate)
            cutoffs = nil
        }
        cutoff = signal
        // Narrow enough that the edge is a tenth of the cutoff; doubling keeps the tap count odd.
        let maximumTaps = 131_073 // maximumLinearPhaseTaps in LinearPhase.h
        var count = 129
        while count < maximumTaps, bake.dsp.linearPhaseTransitionHz(Int32(count), sampleRate) > 0.1 * lowest {
            count = min(count * 2 - 1, maximumTaps)
        }
        let tapCount = Int32(count)
        taps = tapCount
        let doubles = bake.dsp.linearPhaseScratchDoubles(tapCount, moves)
        scratch = (0..<max(channels, 1)).map { _ in
            let buffer = UnsafeMutablePointer<Double>.allocate(capacity: max(doubles, 1))
            buffer.initialize(repeating: 0, count: max(doubles, 1))
            return buffer
        }
    }

    deinit {
        cutoffs?.deallocate()
        for buffer in scratch { buffer.deallocate() }
    }

    func render(channel: Int, input: UnsafeMutablePointer<Float>, inputFrames: Int, into output: UnsafeMutablePointer<Float>, frames: Range<Int>) {
        bake.dsp.renderLinearPhaseFilter(
            .lowpass, taps, cutoff, bake.dsp.ParameterSignal(), bake.dsp.ParameterSignal(), sampleRate,
            input, inputFrames, output, frames.lowerBound, frames.count, scratch[channel]
        )
    }
}
