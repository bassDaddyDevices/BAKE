import BakeDSP
import BakeGraph

/// Utility node: gain, balance, polarity, mono sum, fades, DC removal, whole-file normalisation, and trim and pad.
/// Everything is stateless per frame once the two whole-file measurements (each channel's DC offset, then the
/// normalisation gain) are taken on the first chunk, so it runs across frame ranges as well as channels and matches at
/// any chunk size or core count. The measurements see only the audio that is kept after Trim, never the pads.
final class UtilityProcessor: StepProcessor {
    private var controls = bake.dsp.UtilityControls()
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let plan: PiecePlan
    private let removesDC: Bool
    private let normalize: bake.dsp.UtilityNormalize
    private let target: Double
    private let sampleRate: Double
    private var offsets: [Double]
    private var prepared = false
    private let adjust: AdjustedPlan.Frames
    private let keptFrames: Int
    private let monoSum: Bool
    /// The first kept frame of each channel (or the mono sum, repeated for every channel).
    private var sources: [UnsafePointer<Float>?] = []
    private var summed: UnsafeMutablePointer<Float>?

    init(step: RenderStep, sampleRate: Double, maxChunkFrames: Int, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let input = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        var controls = bake.dsp.UtilityControls()
        controls.gain = bake.dsp.ParameterSignal("gain", of: step, pool: pool)
        controls.balance = bake.dsp.ParameterSignal("balance", of: step, pool: pool)
        if case .choice("inverted")? = step.parameters["polarity"] { controls.polarity = -1 }
        controls.fadeInFrames = max(step.parameters["fadeIn"]?.numberValue ?? 0, 0) * sampleRate
        controls.fadeOutFrames = max(step.parameters["fadeOut"]?.numberValue ?? 0, 0) * sampleRate
        var curveName = "linear"
        if case .choice(let value)? = step.parameters["fadeCurve"] { curveName = value }
        controls.fadeCurve = switch curveName {
        case "equalPower": .equalPower
        case "smooth": .smooth
        default: .linear
        }
        var normalizeName = "off"
        if case .choice(let value)? = step.parameters["normalize"] { normalizeName = value }
        normalize = switch normalizeName {
        case "peak": .peak
        case "rms": .rms
        case "loudness": .loudness
        default: .off
        }
        target = step.parameters["target"]?.numberValue ?? -14
        if case .choice("on")? = step.parameters["dcRemove"] { removesDC = true } else { removesDC = false }
        inputs = (0..<input.shape.channels).map { pool.channel($0, of: input) }
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        let adjustment = AdjustedPlan.frames(step.parameters, sampleRate: sampleRate)
        let inputFrames = inputs.first?.count ?? 0
        let kept = adjustment.kept(of: inputFrames)
        adjust = adjustment
        keptFrames = kept
        monoSum = step.parameters["monoSum"] == .choice("on") && inputs.count > 1
        controls.contentStart = adjustment.padStart
        controls.totalFrames = adjustment.padStart + kept
        self.controls = controls
        self.sampleRate = sampleRate
        offsets = Array(repeating: 0, count: output.shape.channels)
        plan = PiecePlan(channels: output.shape.channels, maxChunkFrames: max(maxChunkFrames, 1), workers: workers)
        if monoSum { try NodeMemory.require(bytes: kept * MemoryLayout<Float>.stride) }
    }

    deinit { summed?.deallocate() }

    /// Points at the kept audio of every channel, summing to mono first when Mono Sum is on.
    private func prepareSources() {
        let start = adjust.trimStart
        let channels: [UnsafePointer<Float>?] = inputs.map { buffer in buffer.baseAddress.map { UnsafePointer($0) + start } }
        guard monoSum, keptFrames > 0 else {
            sources = channels
            return
        }
        let mixed = UnsafeMutablePointer<Float>.allocate(capacity: keptFrames)
        summed = mixed
        channels.withUnsafeBufferPointer { pointers in
            bake.dsp.utilityMonoSum(pointers.baseAddress, Int32(pointers.count), keptFrames, mixed)
        }
        sources = Array(repeating: UnsafePointer(mixed), count: outputs.count)
    }

    func process(frames: Range<Int>) async throws {
        if !prepared {
            prepared = true
            prepareSources()
            if removesDC {
                for channel in offsets.indices {
                    if let base = sources[min(channel, sources.count - 1)] {
                        offsets[channel] = bake.dsp.utilityDcOffset(base, keptFrames)
                    }
                }
            }
            if normalize != .off {
                let frameCount = keptFrames
                controls.normalizeGain = sources.withUnsafeBufferPointer { channels in
                    offsets.withUnsafeBufferPointer { dc in
                        bake.dsp.utilityNormalizeGain(
                            channels.baseAddress, Int32(channels.count), frameCount, dc.baseAddress, normalize, target, sampleRate
                        )
                    }
                }
            }
        }
        let settings = controls
        let channelCount = Int32(outputs.count)
        let contentStart = adjust.padStart, contentEnd = adjust.padStart + keptFrames
        plan.run(channels: outputs.count, frames: frames) { channel, piece, _ in
            guard let destination = outputs[channel].baseAddress else { return }
            let low = piece.lowerBound, high = piece.upperBound
            // Pad Start and Pad End are exact silence: no DC offset, gain or fade ever touches them.
            let beforeEnd = min(high, contentStart)
            if low < beforeEnd { (destination + low).update(repeating: 0, count: beforeEnd - low) }
            let afterStart = max(low, contentEnd)
            if afterStart < high { (destination + afterStart).update(repeating: 0, count: high - afterStart) }
            let from = max(low, contentStart), to = min(high, contentEnd)
            guard from < to, let source = sources[min(channel, sources.count - 1)] else { return }
            bake.dsp.renderUtility(
                settings, Int32(channel), channelCount, source + (from - contentStart), destination + from,
                offsets[channel], from, to - from
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
