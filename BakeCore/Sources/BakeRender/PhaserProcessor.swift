import BakeDSP
import BakeGraph

/// Phaser node on the CPU engine.
///
/// The classic path (forward, up to 64 stages, sweep free-running) is the original kernel with per-channel
/// all-pass memories. Anything else uses the deep kernel, which reads the whole channel:
///
/// - Direction: forward, backward (the chain runs through time in reverse, smearing each transient before it
///   arrives) or zero phase (the average of the two: no phase, no smear).
/// - Up to 512 stages, with coefficients refreshed every 8 frames.
/// - Retrigger: the sweep restarts from a set position at every transient of the file.
///
/// Each channel's state is its own, so channels run in parallel with identical bits on any core count.
final class PhaserProcessor: StepProcessor {
    private let stages: Int32
    private let center: bake.dsp.ParameterSignal
    private let width: bake.dsp.ParameterSignal
    private let rate: bake.dsp.ParameterSignal
    private let depth: bake.dsp.ParameterSignal
    private let feedback: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let stereoOffset: Double
    private let stereoOffsetSignal: bake.dsp.ParameterSignal
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let workers: Int
    private let classicState: ChannelStates<bake.dsp.PhaserState>

    private let direction: bake.dsp.PhaserDirection
    private let retrigger: Bool
    private let sensitivity: Double
    private let startPhase: Double
    private let isDeep: Bool
    /// Forward run of the deep kernel: state per channel, and a chunk of wet signal as scratch.
    private let forwardState: ChannelStates<bake.dsp.PhaserDeepState>?
    /// Backward run: its own state, run once over the whole channel on the first chunk.
    private let backwardState: ChannelStates<bake.dsp.PhaserDeepState>?
    private let sweep: UnsafeMutablePointer<Float>?
    private let backward: [UnsafeMutablePointer<Float>]
    private var prepared = false

    init(
        step: RenderStep, sampleRate: Double, pool: BufferPool,
        maxChunkFrames: Int = 65_536, workers: Int = Parallel.coreCount
    ) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var stageName = "4"
        if case .choice(let value)? = step.parameters["stages"] { stageName = value }
        let stageCount = Int32(stageName) ?? 4
        stages = stageCount
        center = bake.dsp.ParameterSignal("center", of: step, pool: pool)
        width = bake.dsp.ParameterSignal("width", of: step, pool: pool)
        rate = bake.dsp.ParameterSignal("rate", of: step, pool: pool)
        depth = bake.dsp.ParameterSignal("depth", of: step, pool: pool)
        feedback = bake.dsp.ParameterSignal("feedback", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        self.sampleRate = sampleRate
        stereoOffset = step.parameters["stereoOffset"]?.numberValue ?? 0.25
        stereoOffsetSignal = bake.dsp.ParameterSignal("stereoOffset", of: step, pool: pool)
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        self.workers = max(workers, 1)
        classicState = ChannelStates(channels: output.shape.channels, initial: bake.dsp.PhaserState(), historyFloats: 0, scratchFloats: 1)

        // Missing settings are the original behaviour: forward, free-running sweep.
        var directionName = "forward"
        if case .choice(let value)? = step.parameters["direction"] { directionName = value }
        let chosenDirection: bake.dsp.PhaserDirection = switch directionName {
        case "backward": .backward
        case "zeroPhase": .zeroPhase
        default: .forward
        }
        direction = chosenDirection
        var retriggerName = "off"
        if case .choice(let value)? = step.parameters["retrigger"] { retriggerName = value }
        let retriggers = retriggerName == "transients"
        retrigger = retriggers
        sensitivity = step.parameters["retriggerSensitivity"]?.numberValue ?? 0.5
        startPhase = (step.parameters["retriggerPhase"]?.numberValue ?? 270) / 360
        let deep = chosenDirection != .forward || retriggers || stageCount > 64 // maxPhaserStages in Phaser.h
        isDeep = deep

        let channels = output.shape.channels
        let frames = input.shape.frames
        if deep {
            try NodeMemory.require(bytes: (1 + channels) * frames * MemoryLayout<Float>.stride)
            forwardState = chosenDirection == .backward ? nil : ChannelStates(
                channels: channels, initial: bake.dsp.PhaserDeepState(), historyFloats: 0, scratchFloats: maxChunkFrames
            )
            backwardState = chosenDirection == .forward ? nil : ChannelStates(
                channels: channels, initial: bake.dsp.PhaserDeepState(), historyFloats: 0, scratchFloats: 1
            )
            let sweepBuffer = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
            sweepBuffer.initialize(repeating: 0, count: max(frames, 1))
            sweep = sweepBuffer
            backward = chosenDirection == .forward ? [] : (0..<channels).map { _ in
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
                buffer.initialize(repeating: 0, count: max(frames, 1))
                return buffer
            }
        } else {
            forwardState = nil
            backwardState = nil
            sweep = nil
            backward = []
        }
    }

    deinit {
        sweep?.deallocate()
        for buffer in backward { buffer.deallocate() }
    }

    private func side(of channel: Int) -> bake.dsp.PhaserChannel {
        outputs.count == 1 ? .mono : (channel == 0 ? .left : .right)
    }

    /// Whole-file work, once: the transients, the sweep every channel shares, and the backward run.
    private func prepare() {
        guard let sweep else { return }
        let frames = inputs.first?.count ?? 0
        var onsets: [Int32] = []
        if retrigger {
            let channels: [UnsafePointer<Float>?] = inputs.map { $0.baseAddress.map { UnsafePointer($0) } }
            onsets = [Int32](repeating: 0, count: bake.dsp.phaserTransientCapacity(frames, sampleRate))
            let found = channels.withUnsafeBufferPointer { pointers in
                onsets.withUnsafeMutableBufferPointer { storage in
                    bake.dsp.detectPhaserTransients(
                        pointers.baseAddress, pointers.count, frames, sampleRate, sensitivity,
                        storage.baseAddress, storage.count
                    )
                }
            }
            onsets.removeLast(onsets.count - Int(found))
        }
        onsets.withUnsafeBufferPointer { storage in
            bake.dsp.buildPhaserSweep(rate, sampleRate, frames, storage.baseAddress, storage.count, startPhase, sweep)
        }
        guard let backwardState else { return }
        Parallel.forEach(outputs.count, workers: workers) { channel in
            guard let source = inputs[channel].baseAddress else { return }
            bake.dsp.renderPhaserDeep(
                &backwardState.states[channel], side(of: channel), stages, center, width, depth, feedback, sampleRate,
                stereoOffset, stereoOffsetSignal, sweep, source, frames, backward[channel], 0, 0, frames, true
            )
        }
    }

    func process(frames: Range<Int>) async throws {
        guard isDeep, let sweep else {
            Parallel.forEach(outputs.count, workers: workers) { channel in
                guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
                bake.dsp.renderPhaser(
                    &classicState.states[channel], side(of: channel), stages, center, width, rate, depth, feedback, mix, sampleRate, stereoOffset, stereoOffsetSignal,
                    source + frames.lowerBound, destination + frames.lowerBound, frames.lowerBound, frames.count
                )
            }
            return
        }
        if !prepared {
            prepared = true
            prepare()
        }
        Parallel.forEach(outputs.count, workers: workers) { channel in
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
            let total = inputs[channel].count
            var forwardWet: UnsafePointer<Float>?
            if let forwardState {
                let scratch = forwardState.scratch[channel]
                bake.dsp.renderPhaserDeep(
                    &forwardState.states[channel], side(of: channel), stages, center, width, depth, feedback, sampleRate,
                    stereoOffset, stereoOffsetSignal, sweep, source, total, scratch, frames.lowerBound, frames.lowerBound, frames.count, false
                )
                forwardWet = UnsafePointer(scratch)
            }
            bake.dsp.renderPhaserDeepBlend(
                direction, mix, source, total, forwardWet, backward.isEmpty ? nil : UnsafePointer(backward[channel]),
                destination + frames.lowerBound, frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
