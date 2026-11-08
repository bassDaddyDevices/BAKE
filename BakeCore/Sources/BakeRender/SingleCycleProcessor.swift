import BakeDSP
import BakeGraph

/// Wavetable mode: repeated mono cycles of exactly Frame Size samples, controls read once per cycle.
/// Oscillator mode: a free-running cycle at Frequency, controls read per frame.
final class SingleCycleProcessor: StepProcessor {
    private let output: UnsafeMutableBufferPointer<Float>
    private let frameSize: Int
    private let seed: UInt64
    private let partials: [Float]
    private let shapeIndex: bake.dsp.ParameterSignal
    private let fixedShape: bake.dsp.SingleCycleShape
    private let width: bake.dsp.ParameterSignal
    private let phase: bake.dsp.ParameterSignal
    private let warp: bake.dsp.ParameterSignal
    private let morph: bake.dsp.ParameterSignal
    private let harmonic: bake.dsp.ParameterSignal
    private let frequency: bake.dsp.ParameterSignal
    private let isOscillator: Bool
    private let sampleRate: Double
    private var oscillator = bake.dsp.SingleCycleOscillatorState()

    init(step: RenderStep, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"],
              case .choice(let size)? = step.parameters["frameSize"],
              let frameSize = Int(size) else {
            throw RenderError.unsupportedNode(step.kind)
        }
        self.frameSize = frameSize
        output = pool.channel(0, of: binding)
        var shapeName = "saw"
        if case .choice(let choice)? = step.parameters["shape"] { shapeName = choice }
        fixedShape = Self.shape(shapeName)
        shapeIndex = bake.dsp.ParameterSignal("shape", of: step, pool: pool)
        width = bake.dsp.ParameterSignal("width", of: step, pool: pool)
        phase = bake.dsp.ParameterSignal("phase", of: step, pool: pool)
        warp = bake.dsp.ParameterSignal("warp", of: step, pool: pool)
        morph = bake.dsp.ParameterSignal("morph", of: step, pool: pool)
        harmonic = bake.dsp.ParameterSignal("harmonic", of: step, pool: pool)
        frequency = bake.dsp.ParameterSignal("frequency", of: step, pool: pool)
        isOscillator = step.parameters["mode"] == .choice("oscillator")
        self.sampleRate = sampleRate
        // The phase starts at 0; Phase is added on top, as in Wavetable mode.
        seed = UInt64(max((step.parameters["seed"]?.numberValue ?? 1).rounded(), 0))
        let partialsText: String
        if case .text(let text)? = step.parameters["partials"] { partialsText = text } else { partialsText = "1 0.5 0.333 0.25" }
        partials = Self.parsePartials(partialsText)
    }

    private static func shape(_ value: String) -> bake.dsp.SingleCycleShape {
        switch value {
        case "sine": .sine
        case "triangle": .triangle
        case "square": .square
        case "pulse": .pulse
        case "noise": .noise
        case "additive": .additive
        default: .saw
        }
    }

    static func parsePartials(_ text: String) -> [Float] {
        let parsed = text.split(whereSeparator: \.isWhitespace).prefix(64).map { Float($0) ?? 0 }
        return parsed + Array(repeating: 0, count: max(0, 64 - parsed.count))
    }

    func process(frames: Range<Int>) async throws {
        guard let destination = output.baseAddress else { return }
        partials.withUnsafeBufferPointer { partialPointer in
            if isOscillator {
                bake.dsp.renderSingleCycleOscillator(
                    &oscillator, fixedShape, shapeIndex, width, phase, warp, morph, frequency,
                    partialPointer.baseAddress, partialPointer.count, seed, sampleRate,
                    destination + frames.lowerBound, frames.lowerBound, frames.count
                )
            } else {
                bake.dsp.renderSingleCycle(
                    fixedShape, shapeIndex, width, phase, warp, morph, harmonic, partialPointer.baseAddress, partialPointer.count,
                    seed, destination + frames.lowerBound, frameSize, frames.lowerBound, frames.count
                )
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}
}
