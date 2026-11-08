import BakeGraph
import SwiftUI

// More card pictures, in the same spirit as NodeVisualView's: what the node does, drawn from its
// settings with the maths the renderer uses (BakeGraph's plot enums).

/// Feedback's ideal decay train: echo spacing is Delay and each echo falls by Feedback gain.
/// The light stroke denotes the damping bandwidth, which affects tone but not the plotted envelope.
/// Under it, how to wire the loop: Send feeds the chain, the chain's end comes back into Return.
struct FeedbackEchoView: View {
    let echoes: [FeedbackPlot.Echo]

    var body: some View {
        VStack(spacing: 2) {
            echoPlot
            Text("Send → your chain → Return · Out is the result")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var echoPlot: some View {
        Canvas { context, size in
            let inset: CGFloat = 4
            let baseline = size.height - inset
            let height = size.height - inset * 2
            PlotStyle.line(context, from: CGPoint(x: 0, y: baseline), to: CGPoint(x: size.width, y: baseline))
            var path = Path()
            for (index, echo) in echoes.enumerated() {
                let x = echoes.count > 1 ? size.width * CGFloat(index) / CGFloat(echoes.count - 1) : 0
                let y = baseline - height * CGFloat(min(max(echo.amplitude, 0), 1))
                let point = CGPoint(x: x, y: y)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                let opacity = 0.25 + 0.75 * echo.brightness
                context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(.accentColor.opacity(opacity)))
            }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(height: PlotStyle.height - 40)
        .accessibilityLabel("Feedback echo decay")
    }
}

/// A large, non-interactive Macro control; Value remains editable with the standard parameter slider.
struct MacroControlView: View {
    let value: Double
    let label: String
    let widget: String

    var body: some View {
        VStack(spacing: 5) {
            if widget == "slider" {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 8)
                        Capsule().fill(Color.accentColor).frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)), height: 8)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 28)
                .padding(.horizontal, 18)
                .accessibilityLabel("Macro slider preview")
            } else {
                // A 270° gauge from lower left (−135° from the top) to lower right. `trim` starts at
                // 3 o'clock, so both arcs turn 135° to start there; the dot rides the ring's radius (21).
                let amount = min(max(value, 0), 1)
                ZStack {
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(135))
                    Circle()
                        .trim(from: 0, to: CGFloat(amount) * 0.75)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(135))
                    Circle()
                        .fill(.tint)
                        .frame(width: 7, height: 7)
                        .offset(y: -21)
                        .rotationEffect(.degrees(amount * 270 - 135))
                }
                .frame(width: 42, height: 42)
                .accessibilityLabel("Macro dial preview")
            }
            Text(label.isEmpty ? "Macro" : label)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 60)
        .help("Set the target knob to its minimum, then sweep Macro Value from 0 to 1 to cover the target's whole range.")
    }
}

/// A sine and what the Redux node makes of it: the Mode picks the maths, the bit depth sets how many
/// levels the steps have, and the rate divider how long each one lasts. The faint line is the original.
struct ReduxStepView: View {
    let mode: String
    let bits: Double
    /// Bit Steps: false rounds the depth to whole bits, true keeps its fraction.
    let fractionalBits: Bool
    let divider: Int
    let linear: Bool
    let mask: Int
    let operatorName: String

    var body: some View {
        Canvas { context, size in
            // Long enough to show about eight held steps, and never fewer than 128 frames.
            let samples = min(max(divider * 8, 128), 1_024)
            let trace = ReduxPlot.trace(
                mode: mode, bits: bits, fractionalBits: fractionalBits, divider: divider, linear: linear, mask: mask,
                operatorName: operatorName, samples: samples
            )
            func point(_ index: Int, _ value: Double) -> CGPoint {
                CGPoint(x: CGFloat(index) / CGFloat(samples - 1) * size.width, y: (1 - CGFloat(min(max(value, -1.05), 1.05)) / 1.05) / 2 * size.height)
            }
            PlotStyle.line(context, from: CGPoint(x: 0, y: size.height / 2), to: CGPoint(x: size.width, y: size.height / 2))
            var original = Path()
            for (index, value) in trace.input.enumerated() {
                if index == 0 { original.move(to: point(index, value)) } else { original.addLine(to: point(index, value)) }
            }
            context.stroke(original, with: .color(.secondary.opacity(0.45)), lineWidth: 0.75)
            var crushed = Path()
            for (index, value) in trace.output.enumerated() {
                // Hold the previous value until this frame, so a held step draws as a flat tread with a vertical riser.
                if index == 0 { crushed.move(to: point(index, value)) } else {
                    if !linear { crushed.addLine(to: point(index, trace.output[index - 1])) }
                    crushed.addLine(to: point(index, value))
                }
            }
            context.stroke(crushed, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: PlotStyle.height)
        .accessibilityLabel("Bit crusher steps")
    }
}

/// A reference signal and what the node makes of it, scaled to the larger of the two so the shape shows
/// even when the node makes it quiet. The faint line is the original.
struct SignalTraceView: View {
    let input: [Double]
    let output: [Double]
    let label: String

    var body: some View {
        Canvas { context, size in
            let peak = max((input + output).map(abs).max() ?? 1, 1e-6) * 1.05
            func path(_ values: [Double]) -> Path {
                var path = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) / CGFloat(max(values.count - 1, 1)) * size.width,
                        y: (1 - CGFloat(value / peak)) / 2 * size.height
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }
            PlotStyle.line(context, from: CGPoint(x: 0, y: size.height / 2), to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path(input), with: .color(.secondary.opacity(0.45)), lineWidth: 0.75)
            context.stroke(path(output), with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: PlotStyle.height)
        .accessibilityLabel(label)
    }
}

/// Where the Resonator will ring: one line per partial on a log pitch axis, with octave marks.
struct ResonatorPeaksView: View {
    let partials: [Double]

    var body: some View {
        Canvas { context, size in
            let axes = ResponseAxes(size: size, minimumDB: 0, maximumDB: 1)
            // Octaves of C, so the series can be read against pitch.
            var octave = 32.703
            while octave < ResponseAxes.highestHz {
                PlotStyle.line(context, from: CGPoint(x: axes.x(forHz: octave), y: 0), to: CGPoint(x: axes.x(forHz: octave), y: size.height), opacity: 0.12)
                octave *= 2
            }
            var lines = Path()
            for (index, frequency) in partials.enumerated() where frequency >= ResponseAxes.lowestHz && frequency <= ResponseAxes.highestHz {
                let x = axes.x(forHz: frequency)
                let top = index == 0 ? 0.05 : 0.25   // the fundamental stands taller
                lines.move(to: CGPoint(x: x, y: size.height))
                lines.addLine(to: CGPoint(x: x, y: size.height * top))
            }
            context.stroke(lines, with: .style(.tint), lineWidth: 1)
        }
        .frame(height: 56)
        .accessibilityLabel("Resonator partials")
    }
}

/// The Stretch node's analysis window: overlapping Hann windows, four to a window length.
struct StretchWindowView: View {
    let fftSize: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                // Show about 2.5 window lengths so the overlap is visible.
                let span = 2.5
                for index in 0..<7 {
                    let start = Double(index) * 0.25
                    var path = Path()
                    for step in 0...48 {
                        let t = Double(step) / 48
                        let x = (start + t) / span
                        let y = 0.5 - 0.5 * cos(2 * .pi * t)
                        let point = CGPoint(x: x * size.width, y: size.height - CGFloat(y) * (size.height - 4))
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .style(.tint.opacity(index % 4 == 0 ? 1 : 0.4)), lineWidth: 1)
                }
            }
            .frame(height: 44)
            Text("\(fftSize) samples · \(String(format: "%.0f", StretchPlot.windowMilliseconds(fftSize: fftSize, sampleRate: 48_000))) ms, 4× overlap")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stretch analysis window, \(fftSize) samples")
    }
}

/// A short burst with the follower's current one-pole attack and release.
struct EnvelopeFollowerView: View {
    /// Milliseconds, as the catalog stores them.
    let attack: Double
    let release: Double

    var body: some View {
        Canvas { context, size in
            let points = 160
            let attackSeconds = max(attack, 0.1) / 1_000
            let releaseSeconds = max(release, 1) / 1_000
            let duration = max(attackSeconds * 4 + releaseSeconds * 4, 0.08)
            let burstStart = duration * 0.2
            let burstEnd = duration * 0.65
            // Each point is one step of `duration / (points − 1)` seconds.
            let step = duration / Double(points - 1)
            let attackCoefficient = exp(-step / attackSeconds)
            let releaseCoefficient = exp(-step / releaseSeconds)
            var level = 0.0
            var path = Path()
            for index in 0..<points {
                let time = duration * Double(index) / Double(points - 1)
                let target = time >= burstStart && time < burstEnd ? 0.8 : 0
                let coefficient = target > level ? attackCoefficient : releaseCoefficient
                level = target + coefficient * (level - target)
                let point = CGPoint(x: CGFloat(index) / CGFloat(points - 1) * size.width, y: (1 - CGFloat(level)) * (size.height - 6) + 3)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            PlotStyle.line(context, from: CGPoint(x: 0, y: size.height - 3), to: CGPoint(x: size.width, y: size.height - 3))
            context.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Envelope follower attack and release")
    }
}

/// The Pitch Follower: after a bake, the pitch it followed over the first seconds, with how sure it
/// was shaded beneath; before one, a sketch of a melody between Min and Max.
struct PitchFollowerView: View {
    let minFreq: Double
    let maxFreq: Double
    /// The last bake's detail traces (`NodeSummary.detail`), 0…1; empty before a bake.
    let pitch: [Float]
    let confidence: [Float]

    /// A few held notes and a slide, for the picture before a bake.
    private static let sketch: [Double] = [0.3, 0.3, 0.3, 0.55, 0.55, 0.45, 0.45, 0.45, 0.7, 0.7, 0.62, 0.5, 0.4, 0.4]

    var body: some View {
        Canvas { context, size in
            let height = size.height - 6
            func y(_ value: Double) -> CGFloat { (1 - CGFloat(min(max(value, 0), 1))) * height + 3 }
            PlotStyle.line(context, from: CGPoint(x: 0, y: size.height - 3), to: CGPoint(x: size.width, y: size.height - 3))
            if !confidence.isEmpty {
                var shade = Path()
                shade.move(to: CGPoint(x: 0, y: size.height - 3))
                for (index, value) in confidence.enumerated() {
                    let x = CGFloat(index) / CGFloat(max(confidence.count - 1, 1)) * size.width
                    shade.addLine(to: CGPoint(x: x, y: size.height - 3 - CGFloat(min(max(value, 0), 1)) * height * 0.35))
                }
                shade.addLine(to: CGPoint(x: size.width, y: size.height - 3))
                shade.closeSubpath()
                context.fill(shade, with: .style(.tint.opacity(0.2)))
            }
            let values = pitch.isEmpty ? Self.sketch : pitch.map(Double.init)
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) / CGFloat(max(values.count - 1, 1)) * size.width, y: y(value))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            var line = context
            line.opacity = pitch.isEmpty ? 0.45 : 1
            line.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: pitch.isEmpty ? [3, 3] : []))
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Pitch follower, \(Int(minFreq)) to \(Int(maxFreq)) Hz")
    }
}

/// The Envelope's shape for a held gate, with a dot running along it so you can see the stages in time.
struct EnvelopeCurveView: View {
    let attack: Double
    let decay: Double
    let sustain: Double
    let release: Double
    let timeScale: Double
    let shape: String

    var body: some View {
        MovingPlot { time in
            Canvas { context, size in
                let curve = EnvelopePlot.curve(
                    attack: attack, decay: decay, sustain: sustain, release: release, timeScale: timeScale, shape: shape, points: 160
                )
                func point(_ index: Int) -> CGPoint {
                    CGPoint(x: CGFloat(curve.times[index] / curve.duration) * size.width, y: (1 - CGFloat(curve.levels[index])) * (size.height - 6) + 3)
                }
                PlotStyle.line(context, from: CGPoint(x: 0, y: size.height - 3), to: CGPoint(x: size.width, y: size.height - 3))
                for edge in [curve.sustainStart, curve.sustainEnd] {
                    let x = CGFloat(edge / curve.duration) * size.width
                    PlotStyle.line(context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height), opacity: 0.15, dash: [2, 3])
                }
                var path = Path()
                for index in curve.times.indices {
                    if index == 0 { path.move(to: point(0)) } else { path.addLine(to: point(index)) }
                }
                context.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                // One pass through the stages every few seconds, however long the envelope is.
                let position = (time / 4).truncatingRemainder(dividingBy: 1)
                let index = min(Int(position * Double(curve.times.count - 1)), curve.times.count - 1)
                let dot = point(index)
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .style(.tint))
            }
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Envelope shape")
    }
}

/// The Flanger's comb filter, sweeping with its LFO: the faint outlines are the shortest and longest
/// delay, the bright curve is where it is now.
struct FlangerResponseView: View {
    let delay: Double
    let rate: Double
    let depth: Double
    let feedback: Double
    let negative: Bool
    let damping: Double
    let mix: Double

    var body: some View {
        MovingPlot { time in
            Canvas { context, size in
                let axes = ResponseAxes(size: size, minimumDB: -36, maximumDB: 18)
                axes.draw(context)
                func response(lfo: Double) -> Path {
                    axes.curve {
                        FrequencyResponse.flangerDecibels(
                            delayMilliseconds: delay, depth: depth, lfo: lfo, feedback: feedback, negativeFeedback: negative,
                            damping: damping, mix: mix, at: $0
                        )
                    }
                }
                for end in [0.0, 1.0] where depth > 0.01 {
                    context.stroke(response(lfo: end), with: .color(.secondary.opacity(0.35)), lineWidth: 0.75)
                }
                let lfo = FrequencyResponse.flangerSweep(rate: rate, at: time)
                context.stroke(response(lfo: lfo), with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .frame(height: PlotStyle.height)
        .accessibilityLabel("Flanger response")
    }
}

/// The Vocoder's bands on a log pitch axis: one bar per band, riding a drifting stand-in for the
/// modulator's levels. With Formant Shift away from 0 the bars slide to where the carrier will
/// receive them, and the unshifted positions stay behind as ghosts.
struct VocoderBandsView: View {
    let centres: [Double]
    let shiftSemitones: Double

    var body: some View {
        MovingPlot { time in
            Canvas { context, size in
                let axes = ResponseAxes(size: size, minimumDB: 0, maximumDB: 1)
                let ratio = pow(2, shiftSemitones / 12)
                var ghosts = Path()
                var bars = Path()
                for (index, centre) in centres.enumerated() {
                    let position = Double(index) / Double(max(centres.count - 1, 1))
                    let level = 0.5 + 0.35 * sin(6 * position - 1.3 * time) * sin(2 * position + 0.7 * time) + 0.1 * sin(17 * position + 2.1 * time)
                    let top = size.height * (1 - min(max(level, 0.05), 1))
                    if shiftSemitones != 0 {
                        let x = axes.x(forHz: centre)
                        ghosts.move(to: CGPoint(x: x, y: size.height))
                        ghosts.addLine(to: CGPoint(x: x, y: size.height * 0.85))
                    }
                    let shifted = centre * ratio
                    guard shifted >= ResponseAxes.lowestHz, shifted <= ResponseAxes.highestHz else { continue }
                    let x = axes.x(forHz: shifted)
                    bars.move(to: CGPoint(x: x, y: size.height))
                    bars.addLine(to: CGPoint(x: x, y: top))
                }
                context.stroke(ghosts, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                context.stroke(bars, with: .style(.tint), lineWidth: centres.count > 96 ? 0.6 : 1.5)
            }
        }
        .frame(height: 56)
        .accessibilityLabel("Vocoder bands")
    }
}

/// The Chorus's voices: each voice's delay over two drift cycles, one line per voice, with a dot
/// riding each line at the drift rate. A wider Spread fans the lines apart; more Detune swings them further.
struct ChorusVoicesView: View {
    let voices: Int
    let detune: Double
    let spread: Double
    let driftRate: Double
    /// Reach in ms: any Reach, or more than 8 voices, is the swarm, drawn as a sample of its voices.
    var reach: Double = 0

    /// The most voice lines drawn; a swarm of 1,024 shows an even sample of them.
    nonisolated private static let drawnVoices = 48

    private var isSwarm: Bool { ChorusPlot.isSwarm(voices: voices, reachMilliseconds: reach) }

    /// The delays of the voices drawn, `cycles` drift cycles in.
    private func delays(_ cycles: Double) -> [Double] {
        if isSwarm {
            let all = ChorusPlot.swarmDelays(
                voices: voices, detuneCents: detune, spread: spread, driftRate: driftRate, reachMilliseconds: reach, cycles: cycles
            )
            let stride = max(all.count / Self.drawnVoices, 1)
            return Swift.stride(from: 0, to: all.count, by: stride).map { all[$0] }
        }
        return ChorusPlot.voiceDelays(voices: voices, detuneCents: detune, spread: spread, driftRate: driftRate, cycles: cycles)
    }

    /// The delay axis in ms: 0…40 for the classic chorus; the swarm widens it by Reach (below 0 reads the input's future).
    private var axis: ClosedRange<Double> {
        guard isSwarm else { return 0...40 }
        let wobble = (pow(2, detune / 1_200) - 1) * 1_000 / (2 * Double.pi * min(max(driftRate, 0.01), 10))
        let reached = min(max(reach, 0), ChorusPlot.maximumReachMilliseconds) * min(max(spread, 0), 1) + wobble
        return min(0, 6 - reached)...max(40, 18 + reached)
    }

    var body: some View {
        MovingPlot { time in
            Canvas { context, size in
                let range = axis
                func y(_ milliseconds: Double) -> CGFloat {
                    size.height * (1 - CGFloat((min(max(milliseconds, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)))
                }
                if range.lowerBound < 0 {
                    PlotStyle.line(context, from: CGPoint(x: 0, y: y(0)), to: CGPoint(x: size.width, y: y(0)), opacity: 0.3, dash: [2, 3])
                }
                let span = 2.0
                let steps = 120
                let now = (time * driftRate).truncatingRemainder(dividingBy: span)
                let count = delays(0).count
                let tracks = (0...steps).map { delays(Double($0) / Double(steps) * span) }
                let current = delays(now)
                let opacity = count > 16 ? 0.3 : 0.55
                for voice in 0..<count {
                    var path = Path()
                    for step in 0...steps {
                        let point = CGPoint(x: CGFloat(Double(step) / Double(steps)) * size.width, y: y(tracks[step][voice]))
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .style(.tint.opacity(opacity)), lineWidth: 1)
                    let dot = CGPoint(x: CGFloat(now / span) * size.width, y: y(current[voice]))
                    context.fill(Path(ellipseIn: CGRect(x: dot.x - 2.5, y: dot.y - 2.5, width: 5, height: 5)), with: .style(.tint))
                }
            }
        }
        .frame(height: PlotStyle.height)
        .accessibilityLabel(isSwarm ? "Chorus swarm voice delays" : "Chorus voice delays")
    }
}

/// The Dual Filter's response: two paths, Alpha above the Cutoff and Beta below, crossfaded by Morph. The bright curve is the
/// result with the LFO at rest; the faint ones are the two ends of its sweep. Drive is not drawn (it is not linear).
struct DualFilterResponseView: View {
    let alphaType: String
    let betaType: String
    let cutoff: Double
    let q: Double
    let spread: Double
    let morph: Double
    let mix: Double
    let sections: Int
    let zeroPhase: Bool
    let lfoDepth: Double
    let inverted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                let axes = ResponseAxes(size: size, minimumDB: -60, maximumDB: 24)
                axes.draw(context)
                func curve(_ lfo: Double) -> Path {
                    let cutoffs = FrequencyResponse.dualFilterCutoffs(cutoff: cutoff, spread: spread, lfoDepth: lfoDepth, inverted: inverted, lfo: lfo)
                    return axes.curve { hertz in
                        FrequencyResponse.dualFilterDecibels(
                            alphaType: alphaType, betaType: betaType, cutoffs: cutoffs, q: q, morph: morph,
                            sections: sections, zeroPhase: zeroPhase, mix: mix, at: hertz
                        )
                    }
                }
                if lfoDepth > 0 {
                    for lfo in [-1.0, 1.0] {
                        context.stroke(curve(lfo), with: .style(.tint.opacity(0.35)), lineWidth: 1)
                    }
                }
                let rest = FrequencyResponse.dualFilterCutoffs(cutoff: cutoff, spread: spread, lfoDepth: lfoDepth, inverted: inverted, lfo: 0)
                for edge in [rest.alpha, rest.beta] {
                    let x = axes.x(forHz: min(max(edge, ResponseAxes.lowestHz), ResponseAxes.highestHz))
                    PlotStyle.line(context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height), opacity: 0.4, dash: [2, 3])
                }
                context.stroke(curve(0), with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .frame(height: PlotStyle.height)
            Text("\(zeroPhase ? "Zero phase · squared magnitude" : "Minimum phase") · \(sections * 12) dB/oct per path")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dual Filter response")
    }
}

/// The Spectral Resynthesis card: the Tilt as a line of gain against pitch (flat at 0, pivoting about
/// 1 kHz), and two bars for how loud the sines and the noise play. The sound itself is shown by the
/// spectrogram of the last bake below.
struct ResynthesisView: View {
    let partials: Int
    let tilt: Double
    let balance: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                let barWidth: CGFloat = 10
                let plotWidth = size.width - 2 * (barWidth + 6)
                let axes = ResponseAxes(size: CGSize(width: plotWidth, height: size.height), minimumDB: -48, maximumDB: 48)
                PlotStyle.line(context, from: CGPoint(x: 0, y: axes.y(forDB: 0)), to: CGPoint(x: plotWidth, y: axes.y(forDB: 0)))
                PlotStyle.line(context, from: CGPoint(x: axes.x(forHz: 1_000), y: 0), to: CGPoint(x: axes.x(forHz: 1_000), y: size.height), opacity: 0.15)
                var line = Path()
                for step in 0...80 {
                    let hertz = axes.hz(atFraction: Double(step) / 80)
                    let point = CGPoint(x: axes.x(forHz: hertz), y: axes.y(forDB: ResynthesisPlot.tiltDecibels(frequency: hertz, tilt: tilt)))
                    if step == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

                let levels = ResynthesisPlot.levels(balance: balance)
                for (index, level) in [levels.sine, levels.noise].enumerated() {
                    let x = plotWidth + 6 + CGFloat(index) * (barWidth + 6)
                    let height = size.height * CGFloat(level)
                    context.stroke(Path(CGRect(x: x, y: 0, width: barWidth, height: size.height)), with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                    context.fill(Path(CGRect(x: x, y: size.height - height, width: barWidth, height: height)),
                                 with: index == 0 ? .style(.tint) : .color(.secondary))
                }
            }
            .frame(height: 56)
            Text("\(partials) partials · tilt \(tilt.formatted(.number.precision(.fractionLength(0...1)))) dB/oct · sine | noise")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spectral Resynthesis tilt and sine-to-noise balance")
    }
}

/// The Clock's bangs over two bars (eight quarter notes): one raised step per division.
struct ClockPulsesView: View {
    let division: String
    let gateLength: Double   // 0…1

    var body: some View {
        Canvas { context, size in
            let quarters = 8.0
            let length = ClockDivision.quarterNotes(division) ?? 1
            let count = Int((quarters / length).rounded(.down))
            PlotStyle.line(context, from: CGPoint(x: 0, y: size.height - 1), to: CGPoint(x: size.width, y: size.height - 1))
            var pulses = Path()
            for index in 0..<min(count, 512) {
                let x = CGFloat(Double(index) * length / quarters) * size.width
                let width = max(CGFloat(length * gateLength / quarters) * size.width, 1)
                pulses.addRect(CGRect(x: x, y: size.height * 0.2, width: width, height: size.height * 0.8 - 1))
            }
            context.fill(pulses, with: .style(.tint))
        }
        .frame(height: PlotStyle.height)
        .accessibilityLabel("Clock pulses over two bars")
    }
}

/// What Math did in the last bake: A and B as they arrived (faint) and the result (bright), over
/// the first seconds. Shows the actual signals, not a curve from the settings.
struct MathTraceView: View {
    let a: [Float]
    let b: [Float]
    let result: [Float]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                ControlTrace.draw([
                    (a, .color(.secondary.opacity(0.7)), 1),
                    (b, .color(.secondary.opacity(0.35)), 1),
                    (result, .style(.tint), 1.8),
                ], in: context, size: size)
            }
            .frame(height: PlotStyle.height - 14)
            Text("A, B → result · first \(Int(NodeSummary.detailSeconds)) s of the last bake")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Math inputs and result from the last bake")
    }
}

/// The Switch's first 16 steps: one column per bang, one row per output, the playing output filled.
struct SwitchStepsView: View {
    let steps: [Int]
    let outputs: Int
    /// What the rows are: "inputs" for the Switch, "outputs" for the fan-out one.
    var noun = "outputs"

    var body: some View {
        Canvas { context, size in
            guard !steps.isEmpty, outputs > 0 else { return }
            let column = size.width / CGFloat(steps.count)
            let row = size.height / CGFloat(outputs)
            for (index, output) in steps.enumerated() {
                for line in 0..<outputs {
                    let cell = CGRect(x: CGFloat(index) * column + 1, y: CGFloat(line) * row + 1,
                                      width: max(column - 2, 1), height: max(row - 2, 1))
                    let path = Path(roundedRect: cell, cornerRadius: 2)
                    if line == output {
                        context.fill(path, with: .style(.tint))
                    } else {
                        context.fill(path, with: .color(.secondary.opacity(0.12)))
                    }
                }
            }
        }
        .frame(height: min(CGFloat(outputs) * 12, PlotStyle.height))
        .accessibilityLabel("Switch steps: \(noun) \(steps.prefix(8).map { String($0 + 1) }.joined(separator: ", "))")
    }
}

/// Half Time's time map over two windows: where in the source each moment of the output plays from.
/// The dashed diagonal is normal playback; each window starts on it and climbs at Speed, then the
/// next window jumps back to the present.
struct HalfTimeMapView: View {
    let speed: Double

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 3
            let width = size.width, height = size.height - inset * 2
            let windows = 2.0
            func point(time: Double, source: Double) -> CGPoint {
                CGPoint(x: CGFloat(time / windows) * width, y: inset + (1 - CGFloat(source / windows)) * height)
            }
            PlotStyle.line(context, from: point(time: 0, source: 0), to: point(time: windows, source: windows), opacity: 0.4, dash: [3, 3])
            let slope = min(max(speed, 0.001), 1)
            var path = Path()
            for window in 0..<Int(windows) {
                let start = Double(window)
                path.move(to: point(time: start, source: start))
                path.addLine(to: point(time: start + 1, source: start + slope))
            }
            context.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Half Time map: each window plays at \(speed.formatted(.number.precision(.fractionLength(0...3)))) times speed")
    }
}

/// Logic. Threshold and Not: A's level across, the output up, switching high at the rise edge and
/// low at the fall edge (the band between them is the hysteresis). And, Or and Xor: their truth
/// table, lit where the output is high.
struct LogicView: View {
    let operatorName: String
    let threshold: Double
    let hysteresis: Double

    var body: some View {
        Group {
            if ["threshold", "not"].contains(operatorName) {
                Canvas { context, size in
                    let inset: CGFloat = 4
                    let low = size.height - inset, high = inset + 4
                    func x(_ value: Double) -> CGFloat { CGFloat((min(max(value, -1), 1) + 1) / 2) * size.width }
                    let edges = LogicPlot.edges(threshold: threshold, hysteresis: hysteresis)
                    let inverted = operatorName == "not"
                    if edges.rise > edges.fall {
                        let band = CGRect(x: x(edges.fall), y: high, width: x(edges.rise) - x(edges.fall), height: low - high)
                        context.fill(Path(band), with: .style(.tint.opacity(0.12)))
                    }
                    PlotStyle.line(context, from: CGPoint(x: 0, y: low), to: CGPoint(x: size.width, y: low))
                    // Rising: low until the rise edge. Falling: high back down to the fall edge.
                    for (edge, opacity) in [(edges.rise, 1.0), (edges.fall, 0.45)] {
                        var path = Path()
                        let before = inverted ? high : low, after = inverted ? low : high
                        path.move(to: CGPoint(x: 0, y: before))
                        path.addLine(to: CGPoint(x: x(edge), y: before))
                        path.addLine(to: CGPoint(x: x(edge), y: after))
                        path.addLine(to: CGPoint(x: size.width, y: after))
                        context.stroke(path, with: .style(.tint.opacity(opacity)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                }
            } else {
                TruthTable(operatorName: operatorName)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Logic: \(operatorName)")
    }
}

/// And, Or and Xor's four cases: A down the side, B across, lit where the output is high.
private struct TruthTable: View {
    let operatorName: String

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text("B 0").font(.caption2).foregroundStyle(.secondary)
                Text("B 1").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach([false, true], id: \.self) { a in
                GridRow {
                    Text(a ? "A 1" : "A 0").font(.caption2).foregroundStyle(.secondary)
                    ForEach([false, true], id: \.self) { b in
                        let on = LogicPlot.gate(operatorName, a: a, b: b)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.15)))
                            .frame(width: 34, height: 14)
                            .overlay(Text(on ? "1" : "0").font(.caption2.monospaced()).foregroundStyle(on ? .white : .secondary))
                    }
                }
            }
        }
    }
}

/// Gain / VCA: the level each Amount sets, Amount across (−1…1). VCA rises from silence to Gain;
/// Ring Mod passes through zero and flips the signal below it.
struct GainVCAView: View {
    let ringMod: Bool
    let gainDecibels: Double

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 4
            let peak = max(pow(10, gainDecibels / 20), 1)
            let middle = size.height / 2
            func point(_ control: Double) -> CGPoint {
                let level = GainVCAPlot.multiplier(ringMod: ringMod, gainDecibels: gainDecibels, control: control) / peak
                return CGPoint(x: CGFloat((control + 1) / 2) * size.width, y: middle - CGFloat(level) * (middle - inset))
            }
            PlotStyle.line(context, from: CGPoint(x: 0, y: middle), to: CGPoint(x: size.width, y: middle))
            var path = Path()
            path.move(to: point(-1))
            path.addLine(to: point(1))
            context.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel(ringMod ? "Ring modulation by Amount" : "Level follows Amount")
    }
}

/// Mixer: each input's wave in its own lane (the last, the spare a wire fills, is dashed and silent), and
/// on the right their sum, as tall as Gain makes it: 0 dB about two thirds of the height, +12 dB all
/// of it, fading out towards −60 dB.
struct MixerView: View {
    let inputs: Int
    let gainDecibels: Double

    var body: some View {
        Canvas { context, size in
            let count = max(inputs, 1)
            let wired = max(count - 1, 1)
            let split = size.width * 0.42
            let start = size.width * 0.55
            func wave(_ index: Int, _ t: Double) -> Double {
                sin(2 * .pi * (1.5 + Double(index) * 0.85) * t + Double(index) * 1.3)
            }
            for index in 0..<count {
                let lane = size.height / CGFloat(count)
                let middle = lane * (CGFloat(index) + 0.5)
                let silent = index >= wired
                var path = Path()
                for step in 0...40 {
                    let t = Double(step) / 40
                    let y = silent ? middle : middle - CGFloat(wave(index, t)) * lane * 0.3
                    let point = CGPoint(x: 4 + (split - 4) * CGFloat(t), y: y)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .style(.tint.opacity(silent ? 0.35 : 0.7)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: silent ? [3, 3] : []))
            }
            let plus = CGPoint(x: (split + start) / 2, y: size.height / 2)
            var sign = Path()
            sign.move(to: CGPoint(x: plus.x - 4, y: plus.y))
            sign.addLine(to: CGPoint(x: plus.x + 4, y: plus.y))
            sign.move(to: CGPoint(x: plus.x, y: plus.y - 4))
            sign.addLine(to: CGPoint(x: plus.x, y: plus.y + 4))
            context.stroke(sign, with: .color(.secondary), lineWidth: 1.2)

            // The sum, scaled to its own peak, then to Gain.
            let samples = (0...60).map { step in (0..<wired).map { wave($0, Double(step) / 60) }.reduce(0, +) }
            let peak = max(samples.map(abs).max() ?? 1, 1e-6)
            let level = min(max((gainDecibels + 60) / 72, 0), 1)
            let amplitude = CGFloat(level) * (size.height / 2 - 4)
            PlotStyle.line(context, from: CGPoint(x: start, y: size.height / 2), to: CGPoint(x: size.width - 4, y: size.height / 2))
            var sum = Path()
            for (step, value) in samples.enumerated() {
                let point = CGPoint(x: start + (size.width - 4 - start) * CGFloat(step) / 60,
                                    y: size.height / 2 - CGFloat(value / peak) * amplitude)
                if step == 0 { sum.move(to: point) } else { sum.addLine(to: point) }
            }
            context.stroke(sum, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Mixer: \(max(inputs - 1, 1)) inputs summed")
    }
}

/// Reverse: a sound's shape forwards (faint) and backwards, mixed by Mix.
struct ReverseView: View {
    let mix: Double

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 4
            // A plucked note: a sharp attack and a long decay.
            func shape(_ t: Double) -> Double { t < 0.04 ? t / 0.04 : exp(-(t - 0.04) * 4) }
            func path(reversed: Bool) -> Path {
                var path = Path()
                for step in 0...80 {
                    let t = Double(step) / 80
                    let level = shape(reversed ? 1 - t : t)
                    let point = CGPoint(x: CGFloat(t) * size.width, y: size.height - inset - CGFloat(level) * (size.height - inset * 2))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }
            let wet = min(max(mix, 0), 1)
            context.stroke(path(reversed: false), with: .style(.tint.opacity(0.15 + 0.6 * (1 - wet))), lineWidth: 1)
            context.stroke(path(reversed: true), with: .style(.tint.opacity(0.15 + 0.85 * wet)), lineWidth: 1.5)
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Reverse, mix \(Int((mix * 100).rounded())) percent")
    }
}

/// Mid/Side: Left and Right become Mid (what they share, L+R) and Side (where they differ, L−R),
/// or back again.
struct MidSideView: View {
    let encodes: Bool

    var body: some View {
        HStack(spacing: 6) {
            column(encodes ? ["L", "R"] : ["Mid", "Side"])
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            column(encodes ? ["Mid  (L+R)/2", "Side (L−R)/2"] : ["L  Mid+Side", "R  Mid−Side"])
        }
        .font(.caption.monospaced())
        .frame(maxWidth: .infinity)
        .frame(height: PlotStyle.height - 40)
        .accessibilityElement(children: .combine)
    }

    private func column(_ labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Text(label).foregroundStyle(.tint)
            }
        }
    }
}

/// Temporal Shatter: the input's transients (top) land Stretch times further apart (bottom). Each
/// keeps its sharp attack; only the gap after it stretches, as grains or as slowed tape. More
/// Sensitivity finds more transients. The input is drawn at most 8× shorter, so it stays visible.
struct TemporalShatterMapView: View {
    let stretch: Double
    let sensitivity: Double
    let tape: Bool

    private var onsets: [Double] {
        let strong = [0, 0.3, 0.55, 0.8]
        let soft = [0.15, 0.42, 0.68, 0.9]
        return (strong + soft.prefix(Int((min(max(sensitivity, 0), 1) * Double(soft.count)).rounded()))).sorted()
    }

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 4
            let top = inset + 6, bottom = size.height - inset - 6
            let inputWidth = size.width / CGFloat(min(max(stretch, 1), 8))
            PlotStyle.line(context, from: CGPoint(x: 0, y: top), to: CGPoint(x: inputWidth, y: top))
            PlotStyle.line(context, from: CGPoint(x: 0, y: bottom), to: CGPoint(x: size.width, y: bottom))
            let times = onsets
            for (index, onset) in times.enumerated() {
                let from = CGPoint(x: CGFloat(onset) * inputWidth, y: top)
                let to = CGPoint(x: CGFloat(onset) * size.width, y: bottom)
                PlotStyle.line(context, from: from, to: to, opacity: 0.3, dash: [2, 3])
                for (point, height) in [(from, CGFloat(6)), (to, CGFloat(10))] {
                    var spike = Path()
                    spike.move(to: point)
                    spike.addLine(to: CGPoint(x: point.x, y: point.y - height))
                    context.stroke(spike, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                // The stretched gap after this transient, up to the next.
                let end = CGFloat(index + 1 < times.count ? times[index + 1] : 1) * size.width
                let start = to.x + 3
                guard end - start > 4 else { continue }
                if tape {
                    var slope = Path()
                    slope.move(to: CGPoint(x: start, y: bottom - 6))
                    slope.addLine(to: CGPoint(x: end - 2, y: bottom - 2))
                    context.stroke(slope, with: .style(.tint.opacity(0.6)), lineWidth: 1)
                } else {
                    var x = start
                    while x < end - 2 {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: bottom - 5, width: 2.5, height: 2.5)), with: .style(.tint.opacity(0.6)))
                        x += 5
                    }
                }
            }
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Temporal Shatter: transients \(stretch.formatted(.number.precision(.fractionLength(0...1)))) times further apart, gaps filled with \(tape ? "slowed tape" : "grains")")
    }
}

/// One Beat Repeat interval: the input before Offset, then one block per repeat across the Gate,
/// as wide as the repeat and as tall as its level. All lengths in sixteenth notes.
struct BeatRepeatBlocksView: View {
    let interval: Double
    let offset: Double
    let gate: Double
    let grid: Double
    let accelerate: Double
    let decay: Double

    var body: some View {
        Canvas { context, size in
            let total = max(interval, offset + gate, 1)
            let inset: CGFloat = 3
            let height = size.height - inset * 2
            func x(_ sixteenths: Double) -> CGFloat { CGFloat(sixteenths / total) * size.width }
            PlotStyle.line(context, from: CGPoint(x: 0, y: size.height - inset), to: CGPoint(x: size.width, y: size.height - inset))
            var start = offset
            var length = max(grid, 0.001)
            var level = 1.0
            // Past ~200 repeats the blocks are thinner than a pixel; the last one fills the gate.
            for _ in 0..<200 where start < offset + gate {
                let end = min(start + length, offset + gate)
                let rect = CGRect(x: x(start) + 0.5, y: inset + (1 - CGFloat(level)) * height,
                                  width: max(x(end) - x(start) - 1, 0.5), height: max(CGFloat(level) * height, 1))
                context.fill(Path(rect), with: .style(.tint.opacity(0.35 + 0.65 * level)))
                start = end
                length = max(length * accelerate, 1.0 / 256)
                level *= max(1 - decay, 0)
            }
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Beat Repeat: repeats across the gate")
    }
}

/// The Looper's passes as a sawtooth: one ramp per pass, as wide as the pass, rising when it plays
/// forward and falling in reverse, as tall as its level.
struct LooperPassesView: View {
    let passes: Int
    let shrink: Double
    let direction: String
    let decay: Double

    var body: some View {
        Canvas { context, size in
            let count = min(max(passes, 1), 64)
            let lengths = (0..<count).map { pow(min(max(shrink, 0.5), 2), Double($0)) }
            let total = lengths.reduce(0, +)
            let inset: CGFloat = 3
            let height = size.height - inset * 2
            let bottom = size.height - inset
            PlotStyle.line(context, from: CGPoint(x: 0, y: bottom), to: CGPoint(x: size.width, y: bottom))
            var x: CGFloat = 0
            var level = 1.0
            var path = Path()
            for (pass, length) in lengths.enumerated() {
                let width = CGFloat(length / total) * size.width
                let reversed = direction == "reverse" || (direction == "pingPong" && pass % 2 == 1)
                let top = bottom - CGFloat(level) * height
                path.move(to: CGPoint(x: x, y: reversed ? top : bottom))
                path.addLine(to: CGPoint(x: x + width, y: reversed ? bottom : top))
                x += width
                level *= max(1 - decay, 0)
            }
            context.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Looper: \(passes) passes")
    }
}

/// One Stutter burst: a block per repeat, as wide as the repeat, filled for the share Gate leaves
/// open, as tall as its level, with a tick showing where Pan Drift puts it (left to right).
struct StutterRepeatsView: View {
    let repeats: Int
    let shrink: Double
    let gate: Double
    let decay: Double
    let panDrift: Double

    var body: some View {
        Canvas { context, size in
            let count = min(max(repeats, 1), 64)
            let lengths = (0..<count).map { pow(min(max(shrink, 0.5), 2), Double($0)) }
            let total = lengths.reduce(0, +)
            let inset: CGFloat = 3
            let tick: CGFloat = 6
            let height = size.height - inset * 2 - tick
            let bottom = size.height - inset - tick
            PlotStyle.line(context, from: CGPoint(x: 0, y: bottom), to: CGPoint(x: size.width, y: bottom))
            var x: CGFloat = 0
            var level = 1.0
            for (repeatIndex, length) in lengths.enumerated() {
                let width = CGFloat(length / total) * size.width
                let open = width * CGFloat(min(max(gate, 0.05), 1))
                let top = bottom - CGFloat(level) * height
                context.fill(Path(CGRect(x: x + 0.5, y: top, width: max(open - 1, 0.5), height: bottom - top)),
                             with: .style(.tint.opacity(0.35 + 0.65 * level)))
                // Pan folds back between the speakers, as the renderer does.
                let t = (((Double(repeatIndex) * panDrift + 1).truncatingRemainder(dividingBy: 4)) + 4).truncatingRemainder(dividingBy: 4)
                let pan = t <= 2 ? t - 1 : 3 - t
                let tickX = x + width * CGFloat((pan + 1) / 2)
                PlotStyle.line(context, from: CGPoint(x: tickX, y: bottom + 2), to: CGPoint(x: tickX, y: bottom + tick), opacity: 0.6)
                x += width
                level *= max(1 - decay, 0)
            }
        }
        .frame(height: PlotStyle.height - 24)
        .accessibilityLabel("Stutter: \(repeats) repeats")
    }
}

/// Step FX's pattern as cells in rows of 8: click a cell to move it to the next effect, right-click to
/// pick one. Each edit is one undoable change to the `pattern` text.
struct StepCellsView: View {
    let node: NodeID
    let pattern: String
    let steps: Int
    @Binding var project: ProjectFile

    var body: some View {
        let effects = StepFXPattern.effects(pattern, steps: steps)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 2) {
            ForEach(effects.indices, id: \.self) { index in
                let effect = effects[index]
                Button {
                    set(index, to: effect.next)
                } label: {
                    Text(String(effect.symbol))
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(effect == .pass ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                        .frame(maxWidth: .infinity, minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: 3).fill(fill(effect)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    ForEach(StepFXPattern.Effect.allCases, id: \.self) { choice in
                        Button(choice.name) { set(index, to: choice) }
                    }
                }
                .help("Step \(index + 1): \(effect.name)")
                .accessibilityIdentifier("step.\(index)")
                .accessibilityLabel("Step \(index + 1)")
                .accessibilityValue(effect.name)
            }
        }
    }

    /// Pass is a quiet cell; the effects step up in strength of the card's tint, in menu order.
    private func fill(_ effect: StepFXPattern.Effect) -> AnyShapeStyle {
        effect == .pass ? AnyShapeStyle(.secondary.opacity(0.12)) : AnyShapeStyle(.tint.opacity(0.35 + 0.13 * Double(effect.rawValue)))
    }

    private func set(_ index: Int, to effect: StepFXPattern.Effect) {
        let text = StepFXPattern.setting(index, to: effect, in: pattern, steps: steps)
        $project.edit { $0.setParameter("pattern", of: node, to: .text(text)) }
    }
}
