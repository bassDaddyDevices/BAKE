import BakeDSP
import BakeGraph

/// Clock node on the CPU engine: writes its bangs into a mono control buffer. Unmodulated it is
/// stateless (each frame from its own number); with BPM, Division or Gate Length modulated it keeps a
/// running position so the tempo can move.
final class ClockProcessor: StepProcessor {
    private let framesPerDivision: Double
    private let gateLength: Double
    private let output: UnsafeMutableBufferPointer<Float>
    private let controls: bake.dsp.ClockControls
    private let modulated: Bool
    private let quarterNotes = ClockDivision.ids.map { ClockDivision.quarterNotes($0) ?? 1 }
    private var state = bake.dsp.ClockState()

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        var division = "1/4"
        if case .choice(let value)? = step.parameters["division"] { division = value }
        framesPerDivision = ClockDivision.frames(division, bpm: step.parameters["bpm"]?.numberValue ?? 120, sampleRate: sampleRate)
        gateLength = (step.parameters["gateLength"]?.numberValue ?? 10) / 100
        output = pool.channel(0, of: binding)
        var controls = bake.dsp.ClockControls()
        controls.bpm = bake.dsp.ParameterSignal("bpm", of: step, pool: pool)
        controls.division = bake.dsp.ParameterSignal("division", of: step, pool: pool)
        controls.gateLength = bake.dsp.ParameterSignal("gateLength", of: step, pool: pool)
        controls.sampleRate = sampleRate
        self.controls = controls
        modulated = controls.bpm.modulation != nil || controls.division.modulation != nil || controls.gateLength.modulation != nil
    }

    func process(frames: Range<Int>) async throws {
        guard let base = output.baseAddress else { return }
        guard modulated else {
            bake.dsp.renderClock(framesPerDivision, gateLength, base + frames.lowerBound, frames.lowerBound, frames.count)
            return
        }
        quarterNotes.withUnsafeBufferPointer { notes in
            var controls = self.controls
            controls.quarterNotes = notes.baseAddress
            controls.divisionCount = Int32(notes.count)
            bake.dsp.renderClockModulated(&state, controls, base + frames.lowerBound, frames.lowerBound, frames.count)
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
