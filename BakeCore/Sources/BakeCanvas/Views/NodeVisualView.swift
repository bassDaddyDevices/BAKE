import BakeGraph
import SwiftUI

/// The picture at the top of a card: what the node does to a signal, drawn from its current
/// settings with the same maths the renderer uses (BakeGraph's `TransferCurves` and
/// `FrequencyResponse`). Where the node moves (the Phaser's sweep), the picture moves too, at the
/// node's own rate, so a bake you can't hear in real time can still be watched.
struct NodeVisualView: View {
    let kind: NodeKind
    let values: [ParameterID: ParameterValue]
    /// The node's last bake and what was wired into it, for pictures that show real signals.
    var summary: NodeSummary? = nil
    var inputs: [PinID: NodeSummary] = [:]
    /// The node's own outputs by pin, for nodes with more than one (the Pitch Follower).
    var outputs: [PinID: NodeSummary] = [:]

    var body: some View {
        switch kind {
        case .waveshaper:
            let curve = values.choice("curve", "tanh")
            let drive = values.number("intensity", 0.5)
            let bias = values.number("bias", 0)
            let mix = values.number("mix", 1)
            TransferCurveView(label: "Waveshaper curve", mix: mix) {
                TransferCurves.waveshaper(curve: curve, x: $0, intensity: drive, bias: bias)
            }
        case .wavefolder:
            let shape = values.choice("foldShape", "triangle")
            let fold = values.number("fold", 0.35)
            let symmetry = values.number("symmetry", 0)
            let stages = Int(values.choice("stages", "2")) ?? 2
            let saturation = values.number("saturation", 0)
            let mix = values.number("mix", 1)
            TransferCurveView(label: "Wavefolder curve", mix: mix) {
                TransferCurves.wavefolder(shape: shape, x: $0, fold: fold, symmetry: symmetry, stages: stages, saturation: saturation)
            }
        case .derivativeDistortion:
            let trace = DerivativeDistortionPlot.cycle(
                slopeDrive: values.number("slopeDrive", 36), curveDrive: values.number("curveDrive", 0),
                edge: values.number("edge", 0), splay: values.number("splay", 0)
            )
            SignalTraceView(input: trace.input, output: trace.output, label: "Derivative Distortion on a 1 kHz sine")
        case .residualExplosion:
            let trace = ResidualExplosionPlot.trace(
                mode: values.choice("mode", "collapse"), severity: values.number("severity", 0.5),
                residualGain: values.number("residualGain", 18), body: values.number("body", 1)
            )
            SignalTraceView(input: trace.input, output: trace.output, label: "Residual Explosion on a decaying sine")
        case .filters:
            FilterResponseView(
                type: values.choice("type", "lowpass"), cutoff: values.number("cutoff", 1_000), q: values.number("q", 0.707),
                sections: (Int(values.choice("slope", "24")) ?? 24) / 12,
                linearPhaseTaps: values.choice("phase", "minimum") == "linear" ? Int(values.choice("firTaps", "4097")) ?? 4_097 : nil
            )
        case .phaser:
            PhaserResponseView(
                center: values.number("center", 700), width: values.number("width", 2),
                stages: Int(values.choice("stages", "4")) ?? 4, feedback: values.number("feedback", 0.2),
                mix: values.number("mix", 0.5), rate: values.number("rate", 0.3), depth: values.number("depth", 0.6)
            )
        case .distortion:
            let mode = values.choice("mode", "soft")
            let drive = values.number("drive", 6)
            let ceiling = values.number("ceiling", 0)
            TransferCurveView(label: "Distortion curve", mix: values.number("mix", 1)) {
                DistortionPlot.transfer(mode: mode, x: $0, driveDecibels: drive, ceilingDecibels: ceiling)
            }
        case .macro:
            MacroControlView(value: values.number("value", 0), label: values.text("label", "Macro"), widget: values.choice("widget", "dial"))
        case .math where !(summary?.detail.isEmpty ?? true):
            MathTraceView(a: inputs["a"]?.detail ?? [], b: inputs["b"]?.detail ?? [], result: summary?.detail ?? [])
        case .math:
            // Before the first bake: the result curve against A, with B at 0.5.
            let operatorName = values.choice("operator", "add")
            let scale = values.number("scale", 1)
            let low = values.number("clampMin", -16)
            let high = values.number("clampMax", 16)
            TransferCurveView(label: "Math result against A, with B at 0.5", mix: 1) {
                MathPlot.apply(operatorName: operatorName, a: $0, b: 0.5, scale: scale, minimum: low, maximum: high)
            }
        case .chorus:
            ChorusVoicesView(
                voices: Int(values.choice("voices", "4")) ?? 4, detune: values.number("detune", 10),
                spread: values.number("spread", 0.6), driftRate: values.number("driftRate", 0.3),
                reach: values.number("reach", 0)
            )
        case .dualFilter:
            DualFilterResponseView(
                alphaType: values.choice("alphaType", "lowpass"), betaType: values.choice("betaType", "highpass"),
                cutoff: values.number("cutoff", 1_000), q: values.number("q", 0.707), spread: values.number("bandwidth", 1),
                morph: values.number("morph", 0.5), mix: values.number("mix", 1),
                sections: (Int(values.choice("slope", "24")) ?? 24) / 12, zeroPhase: values.choice("phase", "minimum") == "zero",
                lfoDepth: values.number("lfoDepth", 0), inverted: values.choice("lfoPhase", "inverted") == "inverted"
            )
        case .quantizer:
            let scale = values.choice("scale", "chromatic")
            let root = Int(values.choice("root", "0")) ?? 0
            TransferCurveView(label: "Quantizer steps", mix: 1) {
                QuantizerPlot.quantize(scale: scale, root: root, x: $0)
            }
        case .spectralResynthesis:
            ResynthesisView(
                partials: Int(values.number("partials", 128).rounded()), tilt: values.number("tilt", 0),
                balance: values.number("balance", 0.5)
            )
        case .vocoder:
            VocoderBandsView(
                centres: VocoderPlot.centres(bands: Int(values.number("bands", 32).rounded()), spacing: values.choice("spacing", "logarithmic"), sampleRate: 48_000),
                shiftSemitones: values.number("formantShift", 0)
            )
        case .redux:
            ReduxStepView(
                mode: values.choice("reduxMode", "classic"),
                bits: values.number("bitDepth", 8), fractionalBits: values.choice("bitSteps", "fractional") == "fractional",
                divider: Int(values.number("rateDivider", 1).rounded()),
                linear: values.choice("mode", "sampleAndHold") == "linear",
                mask: Int(values.number("mask", 21_845).rounded()),
                operatorName: values.choice("bitwiseOperator", "xor")
            )
        case .resonator:
            ResonatorPeaksView(partials: ResonatorPlot.partials(
                root: values.number("root", 110), fineCents: values.number("fine", 0),
                inharmonicity: values.number("inharmonicity", 0), bands: Int(values.number("bands", 64)), sampleRate: 48_000
            ))
        case .feedback:
            FeedbackEchoView(echoes: FeedbackPlot.echoes(
                gainDecibels: values.number("gain", -6), delayMilliseconds: values.number("delay", 10),
                lowCut: values.number("lowCut", 20), highCut: values.number("highCut", 12_000)
            ))
        case .stretch:
            StretchWindowView(fftSize: Int(values.choice("fftSize", "4096")) ?? 4_096)
        case .envelopeFollower:
            EnvelopeFollowerView(attack: values.number("attack", 10), release: values.number("release", 100))
        case .pitchFollower:
            PitchFollowerView(
                minFreq: values.number("minFreq", 60), maxFreq: values.number("maxFreq", 1_000),
                pitch: summary?.detail ?? [], confidence: outputs["confidence"]?.detail ?? []
            )
        case .envelope:
            EnvelopeCurveView(
                attack: values.number("attack", 0.01), decay: values.number("decay", 0.1), sustain: values.number("sustain", 0.7),
                release: values.number("release", 0.3), timeScale: values.number("timeScale", 1), shape: values.choice("curve", "exponential")
            )
        case .flanger:
            FlangerResponseView(
                delay: values.number("delay", 4), rate: values.number("rate", 0.25), depth: values.number("depth", 0.7),
                feedback: values.number("feedback", 0.35), negative: values.choice("feedbackPolarity", "positive") == "negative",
                damping: values.number("hfDamping", 0.2), mix: values.number("mix", 0.5)
            )
        case .stepSwitch, .stepSwitchFanOut:
            let outputs = Int(values.choice(kind == .stepSwitch ? "inputs" : "outputs", "4")) ?? 4
            let text: String = if case .text(let value)? = values["pattern"] { value } else { "1 2 3 4" }
            SwitchStepsView(
                steps: SwitchSteps.sequence(
                    order: values.choice("order", "forward"), outputs: outputs,
                    pattern: SwitchSteps.pattern(text, outputs: outputs), seed: UInt32(values.number("seed", 0)), count: 16
                ),
                outputs: outputs, noun: kind == .stepSwitch ? "inputs" : "outputs"
            )
        case .beatRepeat:
            BeatRepeatBlocksView(
                interval: (BeatRepeatNotes.quarterNotes(values.choice("interval", "1/1")) ?? 4) * 4,
                offset: values.number("offset", 8).rounded(), gate: values.number("gate", 4).rounded(),
                grid: (BeatRepeatNotes.quarterNotes(values.choice("grid", "1/16")) ?? 0.25) * 4,
                accelerate: values.number("accelerate", 1), decay: values.number("decay", 0)
            )
        case .stutter:
            StutterRepeatsView(
                repeats: Int(values.number("repeats", 8).rounded()), shrink: values.number("shrink", 1),
                gate: values.number("gate", 1), decay: values.number("decay", 0), panDrift: values.number("panDrift", 0)
            )
        case .looper:
            LooperPassesView(
                passes: Int(values.number("passes", 4).rounded()), shrink: values.number("shrink", 1),
                direction: values.choice("direction", "forward"), decay: values.number("decay", 0)
            )
        case .halfTime:
            HalfTimeMapView(speed: values.number("speed", 0.5))
        case .logic:
            LogicView(
                operatorName: values.choice("operator", "threshold"), threshold: values.number("threshold", 0.5),
                hysteresis: values.number("hysteresis", 0)
            )
        case .gainVCA:
            GainVCAView(ringMod: values.choice("mode", "vca") == "ringMod", gainDecibels: values.number("gain", 0))
        case .mixer:
            MixerView(inputs: Int(values.number("inputCount", 2).rounded()), gainDecibels: values.number("gain", 0))
        case .reverse:
            ReverseView(mix: values.number("mix", 1))
        case .midSideEncoder:
            MidSideView(encodes: true)
        case .midSideDecoder:
            MidSideView(encodes: false)
        case .temporalShatter:
            TemporalShatterMapView(
                stretch: values.number("stretch", 4), sensitivity: values.number("sensitivity", 0.5),
                tape: values.choice("mode", "grains") == "tape"
            )
        case .clock:
            ClockPulsesView(division: values.choice("division", "1/4"), gateLength: values.number("gateLength", 10) / 100)
        default:
            EmptyView()
        }
    }
}

extension Dictionary where Key == ParameterID, Value == ParameterValue {
    func number(_ id: ParameterID, _ fallback: Double) -> Double { self[id]?.numberValue ?? fallback }

    func text(_ id: ParameterID, _ fallback: String) -> String {
        if case .text(let text)? = self[id] { text } else { fallback }
    }

    func choice(_ id: ParameterID, _ fallback: String) -> String {
        if case .choice(let choice)? = self[id] { choice } else { fallback }
    }
}

// MARK: - Shared drawing

/// Grid lines and the frame every plot sits in.
enum PlotStyle {
    static let height: CGFloat = 84

    static func line(_ context: GraphicsContext, from: CGPoint, to: CGPoint, opacity: Double = 0.25, dash: [CGFloat] = []) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(.secondary.opacity(opacity)), style: StrokeStyle(lineWidth: 0.5, dash: dash))
    }
}

/// Whether to hold still: the system's Reduce Motion setting.
struct MovingPlot<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cardAnimations) private var cardAnimations
    /// Called with the seconds since the plot appeared (0 when motion is reduced or animations are off).
    let content: (Double) -> Content
    @State private var start = Date.now

    var body: some View {
        if reduceMotion || !cardAnimations {
            content(0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                content(timeline.date.timeIntervalSince(start))
            }
        }
    }
}

// MARK: - Transfer curve (Waveshaper, Wavefolder)

/// Output against input for a signal from −1 to +1, with the straight "no change" diagonal behind
/// it. A dot rides the curve as a test tone sweeps through it.
struct TransferCurveView: View {
    let label: String
    /// Dry/wet: the curve shown is what you'd hear, so Mix pulls it towards the diagonal.
    let mix: Double
    let transfer: @Sendable (Double) -> Double

    var body: some View {
        MovingPlot { time in
            Canvas { context, size in
                let side = min(size.width, size.height)
                let frame = CGRect(x: (size.width - side) / 2, y: 0, width: side, height: side)
                func point(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: frame.minX + (x + 1) / 2 * frame.width, y: frame.maxY - (min(max(y, -1.1), 1.1) + 1) / 2 * frame.height)
                }
                PlotStyle.line(context, from: point(-1, 0), to: point(1, 0))
                PlotStyle.line(context, from: point(0, -1), to: point(0, 1))
                PlotStyle.line(context, from: point(-1, -1), to: point(1, 1), opacity: 0.35, dash: [3, 3])
                context.stroke(Path(frame), with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)

                let blend = min(max(mix, 0), 1)
                func output(_ x: Double) -> Double { x + blend * (transfer(x) - x) }
                var path = Path()
                let steps = 240
                for step in 0...steps {
                    let x = Double(step) / Double(steps) * 2 - 1
                    let p = point(x, output(x))
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

                let x = 0.95 * sin(2 * .pi * 0.5 * time)
                let marker = point(x, output(x))
                context.fill(Path(ellipseIn: CGRect(x: marker.x - 3, y: marker.y - 3, width: 6, height: 6)), with: .style(.tint))
            }
        }
        .frame(height: PlotStyle.height)
        .accessibilityLabel(label)
    }
}

// MARK: - Frequency response (Filters, Phaser)

/// Frequency on a log axis from 20 Hz to 20 kHz, gain in dB on the vertical axis.
struct ResponseAxes {
    static let lowestHz = 20.0
    static let highestHz = 20_000.0

    let size: CGSize
    let minimumDB: Double
    let maximumDB: Double

    func x(forHz hz: Double) -> CGFloat {
        CGFloat(log(hz / Self.lowestHz) / log(Self.highestHz / Self.lowestHz)) * size.width
    }

    func y(forDB db: Double) -> CGFloat {
        let clamped = min(max(db, minimumDB), maximumDB)
        return CGFloat(1 - (clamped - minimumDB) / (maximumDB - minimumDB)) * size.height
    }

    func hz(atFraction fraction: Double) -> Double {
        Self.lowestHz * pow(Self.highestHz / Self.lowestHz, fraction)
    }

    func draw(_ context: GraphicsContext) {
        for hz in [100.0, 1_000.0, 10_000.0] {
            PlotStyle.line(context, from: CGPoint(x: x(forHz: hz), y: 0), to: CGPoint(x: x(forHz: hz), y: size.height), opacity: 0.18)
        }
        PlotStyle.line(context, from: CGPoint(x: 0, y: y(forDB: 0)), to: CGPoint(x: size.width, y: y(forDB: 0)), opacity: 0.4, dash: [3, 3])
    }

    func curve(_ decibels: (Double) -> Double) -> Path {
        var path = Path()
        let steps = 200
        for step in 0...steps {
            let hz = hz(atFraction: Double(step) / Double(steps))
            let point = CGPoint(x: x(forHz: hz), y: y(forDB: decibels(hz)))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// The Filters node's gain curve, with its cutoff marked. A steeper Slope draws a steeper edge; in
/// linear-phase mode the edge is as steep as the FIR length allows and a caption says so.
struct FilterResponseView: View {
    let type: String
    let cutoff: Double
    let q: Double
    let sections: Int
    /// The FIR length when the filter is linear phase.
    var linearPhaseTaps: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                let axes = ResponseAxes(size: size, minimumDB: -60, maximumDB: 24)
                axes.draw(context)
                let cutoffX = axes.x(forHz: min(max(cutoff, ResponseAxes.lowestHz), ResponseAxes.highestHz))
                PlotStyle.line(context, from: CGPoint(x: cutoffX, y: 0), to: CGPoint(x: cutoffX, y: size.height), opacity: 0.45, dash: [2, 3])
                let path = axes.curve { hertz in
                    if let taps = linearPhaseTaps {
                        return FrequencyResponse.linearPhaseDecibels(type: type, cutoff: cutoff, q: q, taps: taps, at: hertz)
                    }
                    return FrequencyResponse.filterDecibels(type: type, cutoff: cutoff, q: q, sections: max(sections, 1), at: hertz)
                }
                var fill = path
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .style(.tint.opacity(0.12)))
                context.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .frame(height: PlotStyle.height)
            if let taps = linearPhaseTaps {
                Text("Linear phase · \(taps) taps · \(String(format: "%.1f", FrequencyResponse.linearPhaseTransitionHertz(taps: taps))) Hz edge · no delay")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(linearPhaseTaps == nil ? "Filter response" : "Linear-phase filter response")
    }
}

/// The Phaser's gain curve, sweeping with its own LFO: the faint outlines are the two ends of the
/// sweep, the bright curve is where it is now.
struct PhaserResponseView: View {
    let center: Double
    let width: Double
    let stages: Int
    let feedback: Double
    let mix: Double
    let rate: Double
    let depth: Double

    var body: some View {
        MovingPlot { time in
            Canvas { context, size in
                let axes = ResponseAxes(size: size, minimumDB: -36, maximumDB: 18)
                axes.draw(context)
                func response(sweep: Double) -> Path {
                    axes.curve {
                        FrequencyResponse.phaserDecibels(
                            center: center, width: width, stages: stages, feedback: feedback, mix: mix, sweepOctaves: sweep, at: $0
                        )
                    }
                }
                let reach = min(max(depth, 0), 1) * min(max(width, 0.25), 4) * 0.5   // octaves either side of Center
                for end in [reach, -reach] where abs(end) > 0.01 {
                    context.stroke(response(sweep: end), with: .color(.secondary.opacity(0.35)), lineWidth: 0.75)
                }
                let sweep = FrequencyResponse.phaserSweepOctaves(depth: depth, width: width, rate: rate, at: time)
                context.stroke(response(sweep: sweep), with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .frame(height: PlotStyle.height)
        .accessibilityLabel("Phaser response")
    }
}

extension EnvironmentValues {
    /// Whether card pictures move (Settings › Animate card pictures). Off holds every one still,
    /// as Reduce Motion does, to save CPU and GPU on big patches. Bakes are unaffected.
    @Entry public var cardAnimations = true
}
