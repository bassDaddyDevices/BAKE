import BakeDSP
import BakeGraph

/// Chorus/Ensemble node on the CPU engine. Two paths:
///
/// - Classic (up to 8 voices, Reach 0): the original multi-voice fractional delay, a circular delay line and the
///   wobble phases carried per channel.
/// - Swarm (more voices, or any Reach): every voice reads the whole input directly, so its delay can be negative
///   (the input's future) and as long as Reach. The wobble phase every voice shares is built once for the file, so a
///   frame depends on nothing before it and frame ranges run on every core with identical bits.
final class ChorusProcessor: StepProcessor {
    private let channelState: ChannelStates<bake.dsp.ChorusState>
    private let workers: Int
    private let detune: bake.dsp.ParameterSignal
    private let spread: bake.dsp.ParameterSignal
    private let mix: bake.dsp.ParameterSignal
    private let voices: Int32
    private let driftRate: Double
    private let panSpread: Double
    private let driftSignal: bake.dsp.ParameterSignal
    private let panSignal: bake.dsp.ParameterSignal
    private let sampleRate: Double
    private let delayLineFrames: Int
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]

    private let isSwarm: Bool
    private let swarm: bake.dsp.ChorusSwarm
    private let plan: PiecePlan?
    /// One voice table per channel, and the wobble phase at every frame; allocated once, the phase filled on the first chunk.
    private let tables: [UnsafeMutablePointer<Double>]
    private let drift: UnsafeMutablePointer<Double>?
    private var prepared = false

    init(
        step: RenderStep, sampleRate: Double, pool: BufferPool,
        maxChunkFrames: Int = 65_536, workers: Int = Parallel.coreCount
    ) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        detune = bake.dsp.ParameterSignal("detune", of: step, pool: pool)
        spread = bake.dsp.ParameterSignal("spread", of: step, pool: pool)
        mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        var voiceCount = "4"
        if case .choice(let value)? = step.parameters["voices"] { voiceCount = value }
        let chosenVoices = Int32(voiceCount) ?? 4
        voices = chosenVoices
        driftRate = step.parameters["driftRate"]?.numberValue ?? 0.3
        panSpread = step.parameters["panSpread"]?.numberValue ?? 0.5
        driftSignal = bake.dsp.ParameterSignal("driftRate", of: step, pool: pool)
        panSignal = bake.dsp.ParameterSignal("panSpread", of: step, pool: pool)
        self.sampleRate = sampleRate
        // 12 ms centre + 6 ms spread + up to ~56 ms of wobble (30 ct at the slowest drift) fits in 100 ms.
        delayLineFrames = Int((sampleRate * 0.1).rounded(.up)) + 8
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        self.workers = max(workers, 1)
        let channels = output.shape.channels
        channelState = ChannelStates(
            channels: channels, initial: bake.dsp.ChorusState(), historyFloats: delayLineFrames, scratchFloats: 1
        )

        // Missing Reach is the original behaviour. More than 8 voices can only be the swarm.
        let reach = step.parameters["reach"]?.numberValue ?? 0
        let swarming = chosenVoices > 8 || reach > 0
        isSwarm = swarming
        var controls = bake.dsp.ChorusSwarm()
        controls.detune = detune
        controls.spread = spread
        controls.mix = mix
        controls.driftSignal = driftSignal
        controls.panSignal = panSignal
        controls.voices = chosenVoices
        controls.driftRate = driftRate
        controls.panSpread = panSpread
        controls.sampleRate = sampleRate
        swarm = controls
        if swarming {
            try NodeMemory.require(
                bytes: (channels * Int(bake.dsp.chorusSwarmTableDoubles(chosenVoices)) + max(input.shape.frames, 1)) * MemoryLayout<Double>.stride
            )
            plan = PiecePlan(channels: channels, maxChunkFrames: maxChunkFrames, workers: workers)
            let size = bake.dsp.chorusSwarmTableDoubles(chosenVoices)
            tables = (0..<channels).map { channel in
                let table = UnsafeMutablePointer<Double>.allocate(capacity: max(size, 1))
                table.initialize(repeating: 0, count: max(size, 1))
                bake.dsp.buildChorusSwarmTable(chosenVoices, reach, sampleRate, channel, table)
                return table
            }
            let frames = max(input.shape.frames, 1)
            let phase = UnsafeMutablePointer<Double>.allocate(capacity: frames)
            phase.initialize(repeating: 0, count: frames)
            drift = phase
        } else {
            plan = nil
            tables = []
            drift = nil
        }
    }

    deinit {
        for table in tables { table.deallocate() }
        drift?.deallocate()
    }

    func process(frames: Range<Int>) async throws {
        if isSwarm, let plan, let drift {
            if !prepared {
                prepared = true
                bake.dsp.buildChorusDrift(driftSignal, driftRate, sampleRate, inputs.first?.count ?? 0, drift)
            }
            plan.run(channels: outputs.count, frames: frames) { channel, piece, _ in
                guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
                bake.dsp.renderChorusSwarm(
                    swarm, outputs.count > 1 && channel == 1, tables[channel], drift, source, inputs[channel].count,
                    destination + piece.lowerBound, piece.lowerBound, piece.count
                )
            }
            return
        }
        Parallel.forEach(outputs.count, workers: workers) { channel in
            guard let source = inputs[channel].baseAddress, let destination = outputs[channel].baseAddress else { return }
            // The right channel's wobble offset; nonzero marks the right channel when Pan Spread is modulated.
            let phase = outputs.count > 1 && channel == 1 ? Double.pi * (panSignal.modulation == nil ? panSpread : 1) : 0
            bake.dsp.renderChorus(
                &channelState.states[channel], detune, spread, mix, voices, driftRate, panSpread, driftSignal, panSignal, sampleRate, phase,
                channelState.histories[channel], delayLineFrames, source + frames.lowerBound, destination + frames.lowerBound,
                frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
