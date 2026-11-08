import BakeDSP
import BakeGraph
import Foundation

/// Delay node on the CPU engine. Each channel has a circular line indexed by absolute frame, so a chunk needs nothing
/// from the one before it but the line and the damping filter. With Ping-Pong the channels feed each other, so a stereo
/// pair is rendered together on one thread; otherwise channels run across the cores.
final class DelayProcessor: StepProcessor {
    private let channelState: ChannelStates<bake.dsp.DelayState>
    private let controls: bake.dsp.DelayControls
    private let input: bake.dsp.AudioInput
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    private let lines: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let chunkOutputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let tapFrames: UnsafeMutablePointer<Double>
    private let tapGains: UnsafeMutablePointer<Float>
    private let tapReversed: UnsafeMutablePointer<UInt8>
    /// Pitch per Repeat's read buffers, one per channel, in one allocation (nil when it is off).
    private let shifterStorage: UnsafeMutablePointer<Float>?
    private let shifterLines: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let crossing: Bool
    private let workers: Int

    /// "375 500r@-6 750@-12": times in ms, an `r` after the time to play that tap backwards, then an optional level in dB.
    static func parseTaps(_ text: String) -> [(milliseconds: Double, gain: Float, reversed: Bool)] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).prefix(32).compactMap { token in
            let parts = token.split(separator: "@", maxSplits: 1)
            guard var first = parts.first else { return nil }
            var reversed = false
            if let last = first.last, last == "r" || last == "R" {
                reversed = true
                first = first.dropLast()
            }
            guard let milliseconds = Double(first), milliseconds > 0, milliseconds.isFinite else { return nil }
            let decibels = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
            return (min(milliseconds, 60_000), Float(pow(10, decibels / 20)), reversed)
        }
    }

    init(step: RenderStep, sampleRate: Double, pool: BufferPool, workers: Int = Parallel.coreCount) throws {
        guard let source = step.inputs["in"], let output = step.outputs["out"] else {
            throw RenderError.unsupportedNode(step.kind)
        }
        input = bake.dsp.AudioInput("in", of: step, pool: pool)
        var controls = bake.dsp.DelayControls()
        controls.time = bake.dsp.ParameterSignal("time", of: step, pool: pool)
        controls.feedback = bake.dsp.ParameterSignal("feedback", of: step, pool: pool)
        controls.damping = bake.dsp.ParameterSignal("damping", of: step, pool: pool)
        controls.mix = bake.dsp.ParameterSignal("mix", of: step, pool: pool)
        controls.pingPong = step.parameters["pingPong"]?.numberValue ?? 0
        controls.sampleRate = sampleRate
        var tapText = ""
        if case .text(let value)? = step.parameters["taps"] { tapText = value }
        let taps = Self.parseTaps(tapText)
        tapFrames = .allocate(capacity: max(taps.count, 1))
        tapGains = .allocate(capacity: max(taps.count, 1))
        tapReversed = .allocate(capacity: max(taps.count, 1))
        for (index, tap) in taps.enumerated() {
            tapFrames[index] = tap.milliseconds * 0.001 * sampleRate
            tapGains[index] = tap.gain
            tapReversed[index] = tap.reversed ? 1 : 0
        }
        controls.tapFrames = UnsafePointer(tapFrames)
        controls.tapGains = UnsafePointer(tapGains)
        controls.tapReversed = UnsafePointer(tapReversed)
        controls.tapCount = taps.count
        // A modulated Time can reach the top of its range, so the line is sized for that.
        let timeReach = controls.time.modulation != nil ? Double(controls.time.maximum) : Double(controls.time.base)
        // A reversed tap plays the last T back as grains that read up to 2T behind, so it needs twice the line.
        let reach = max(timeReach, taps.map { $0.reversed ? $0.milliseconds * 2 : $0.milliseconds }.max() ?? 0)
        let lineFrames = Int(bake.dsp.delayLineFrames(reach, sampleRate))
        controls.lineFrames = lineFrames
        outputs = (0..<output.shape.channels).map { pool.channel($0, of: output) }
        let channels = outputs.count
        // Pitch per Repeat reads the echo through a short two-head crossfade; Time is shortened by half of it.
        let semitones = step.parameters["pitch"]?.numberValue ?? 0
        var shifterFrames = 0
        if semitones != 0 {
            let timeFrames = Double(controls.time.base) * 0.001 * sampleRate
            let window = min(max(timeFrames * 0.5, 256), 0.04 * sampleRate).rounded(.down)
            shifterFrames = Int(window) + 64
            controls.pitchSemitones = semitones
            controls.shifterWindow = window
            controls.shifterFrames = shifterFrames
        }
        try NodeMemory.require(bytes: channels * (lineFrames + shifterFrames) * MemoryLayout<Float>.stride)
        shifterLines = .allocate(capacity: max(channels, 1))
        if shifterFrames > 0 {
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: channels * shifterFrames)
            storage.initialize(repeating: 0, count: channels * shifterFrames)
            shifterStorage = storage
            for channel in 0..<channels { shifterLines[channel] = storage + channel * shifterFrames }
            controls.shifterLines = UnsafePointer(shifterLines)
        } else {
            shifterStorage = nil
            for channel in 0..<channels { shifterLines[channel] = nil }
        }
        // The last 50 ms of the tail fade out; a Tail of 0 leaves the output as long as the input and unfaded.
        let total = outputs.first?.count ?? 0
        let tailFrames = max(total - source.shape.frames, 0)
        if tailFrames > 0 {
            let fade = min(Int(0.05 * sampleRate), tailFrames)
            controls.tailFadeStart = Double(total - fade)
            controls.tailFadeEnd = Double(total)
        }
        // Freeze: the loop takes over from Freeze Start (when that is inside the render), over 20 ms.
        if step.parameters["freeze"] == .choice("on") {
            let start = max(step.parameters["freezeStart"]?.numberValue ?? 1, 0) * sampleRate
            if start < Double(total) {
                controls.freezeFrame = start.rounded()
                controls.freezeFade = 0.02 * sampleRate
            }
        }
        self.controls = controls
        channelState = ChannelStates(channels: channels, initial: bake.dsp.DelayState(), historyFloats: lineFrames, scratchFloats: 1)
        lines = .allocate(capacity: max(channels, 1))
        chunkOutputs = .allocate(capacity: max(channels, 1))
        for channel in 0..<channels {
            lines[channel] = channelState.histories[channel]
            chunkOutputs[channel] = nil
        }
        crossing = controls.pingPong > 0 && channels >= 2
        self.workers = max(workers, 1)
    }

    deinit {
        tapFrames.deallocate()
        tapGains.deallocate()
        tapReversed.deallocate()
        shifterStorage?.deallocate()
        shifterLines.deallocate()
        lines.deallocate()
        chunkOutputs.deallocate()
    }

    func process(frames: Range<Int>) async throws {
        for channel in outputs.indices {
            chunkOutputs[channel] = outputs[channel].baseAddress.map { $0 + frames.lowerBound }
        }
        let channels = outputs.count
        // Ping-Pong couples channels in pairs; each pair (or lone channel) is one task.
        let groupSize = crossing ? 2 : 1
        let groups = (channels + groupSize - 1) / groupSize
        Parallel.forEach(groups, workers: workers) { group in
            let first = group * groupSize
            let count = min(groupSize, channels - first)
            bake.dsp.renderDelay(
                channelState.states + first, lines + first, chunkOutputs + first, Int32(count), Int32(first),
                input, controls, frames.lowerBound, frames.count
            )
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
