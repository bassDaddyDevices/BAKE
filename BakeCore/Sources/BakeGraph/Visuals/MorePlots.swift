import Foundation

/// The Distortion card's curve: output against input for a signal from −1 to +1, before oversampling
/// and Mix. Mirrors `shape` in BakeDSP/Distortion.cpp; `PlotMathTests` renders the kernel and compares.
public enum DistortionPlot {
    public static func transfer(mode: String, x: Double, driveDecibels: Double, ceilingDecibels: Double) -> Double {
        let gain = pow(10, driveDecibels / 20)
        let limit = pow(10, ceilingDecibels / 20)
        let driven = x * gain
        return mode == "hard" ? min(max(driven, -limit), limit) : limit * tanh(driven / limit)
    }
}

/// The Derivative Distortion card's trace: a full-scale 1 kHz sine, and what the node makes of it, at
/// 48 kHz without oversampling. Mirrors `step` in BakeDSP/DerivativeDistortion.cpp; the last of four
/// cycles is returned, so the loop has settled. `MorePlotMathTests` renders the kernel and compares.
public enum DerivativeDistortionPlot {
    public static let samplesPerCycle = 48

    public static func cycle(
        slopeDrive: Double, curveDrive: Double, edge: Double, splay: Double
    ) -> (input: [Double], output: [Double]) {
        let rate = 48_000.0
        func limitScale(_ decibels: Double) -> Double { rate / (2 * Double.pi * 20_000 * pow(2, -decibels / 6)) }
        let k = slopeDrive > 0 ? limitScale(slopeDrive) : 0
        let rising = k * pow(2, splay)
        let falling = k * pow(2, -splay)
        let curve = curveDrive > 0 ? limitScale(curveDrive) * limitScale(curveDrive) : 0
        let edgeLowpass = exp(-2 * Double.pi * 5_000 / rate)
        let dcPole = exp(-2 * Double.pi * 5 / rate)
        func soft(_ value: Double, _ k: Double) -> Double { k > 0 ? tanh(k * value) / k : value }
        var y = 0.0, slope = 0.0, lowpass = 0.0, target1 = 0.0, error1 = 0.0, blocked = 0.0
        var input: [Double] = []
        var output: [Double] = []
        for n in 0..<(4 * samplesPerCycle) {
            // The kernel reads Float audio: round the sine the same way.
            let x = Double(Float(sin(2 * Double.pi * 1_000 * Double(n) / rate)))
            lowpass = edgeLowpass * lowpass + (1 - edgeLowpass) * x
            let target = x + edge * (x - lowpass)
            let distance = target - y
            var wanted = distance
            if curve > 0 {
                let speed = target - target1
                let gap = distance - speed
                let brake = sqrt(2 * abs(gap) / curve)
                wanted = speed + min(max(gap, -brake), brake)
                wanted = slope + soft(wanted - slope, curve)
            }
            target1 = target
            slope = soft(wanted, wanted >= 0 ? rising : falling)
            y += slope
            let error = y - target
            blocked = error - error1 + dcPole * blocked
            error1 = error
            if n >= 3 * samplesPerCycle {
                input.append(x)
                output.append(target + blocked)
            }
        }
        return (input, output)
    }
}

/// The Residual Explosion card's trace: a decaying sine (so Sparsify's quiet tail shows) and what the
/// node makes of it. Mirrors ResidualExplosion.metal with the mapping in ResidualExplosionKernel.swift.
public enum ResidualExplosionPlot {
    public static func trace(
        mode: String, severity: Double, residualGain: Double, body: Double, samples: Int = 256
    ) -> (input: [Double], output: [Double]) {
        let severity = min(max(severity, 0), 1)
        let levels = pow(2, 15 - 15 * severity)
        let threshold = pow(10, (-72 + 66 * severity) / 20)
        let gain = pow(10, min(max(residualGain, 0), 60) / 20)
        let body = min(max(body, 0), 1)
        let input = (0..<samples).map { n -> Double in
            let t = Double(n) / Double(samples)
            return sin(2 * Double.pi * 3 * t) * exp(-5 * t)
        }
        let output = input.map { x -> Double in
            let simplified = mode == "sparsify" ? (abs(x) < threshold ? 0 : x) : (x * levels).rounded() / levels
            return body * simplified + tanh(gain * (x - simplified))
        }
        return (input, output)
    }
}

/// The Redux card's trace: a sine, and what the Mode makes of it. Mirrors `renderRedux` in
/// BakeDSP/Redux.cpp (without dither or the anti-alias filter).
public enum ReduxPlot {
    /// Levels per side, as `levelsFor` in Redux.cpp: whole bits round the depth; fractional bits keep it
    /// (3.5 bits = 2^2.5 levels).
    public static func levels(bits: Double, fractional: Bool) -> Double {
        if !fractional {
            return pow(2, Double(min(max(Int(bits.rounded()), 1), 32) - 1))
        }
        let clamped = min(max(bits, 1), 32)
        return pow(2, clamped - 1)
    }

    public static func quantize(_ x: Double, bits: Double, fractional: Bool = true) -> Double {
        let step = 1 / levels(bits: bits, fractional: fractional)
        return min(max((x / step).rounded() * step, -1), 1)
    }

    public static func quantize(_ x: Double, bits: Int) -> Double {
        quantize(x, bits: Double(bits), fractional: true)
    }

    public static func trace(
        mode: String, bits: Int, divider: Int, linear: Bool, mask: Int, operatorName: String, samples: Int
    ) -> (input: [Double], output: [Double]) {
        trace(
            mode: mode, bits: Double(bits), fractionalBits: true, divider: divider, linear: linear, mask: mask,
            operatorName: operatorName, samples: samples
        )
    }

    /// `samples` frames of a sine with two cycles across them, and the crushed version of it.
    /// `mode` follows the Mode setting: classic = bits then rate; bitReduction = bits only;
    /// downsampling/sampleAndHold = rate only; bitwise = the integer operation. `fractionalBits` is Bit Steps.
    public static func trace(
        mode: String, bits: Double, fractionalBits: Bool, divider: Int, linear: Bool, mask: Int, operatorName: String, samples: Int
    ) -> (input: [Double], output: [Double]) {
        let interval = min(max(divider, 1), 256)
        let input = (0..<samples).map { sin(2 * Double.pi * 2 * Double($0) / Double(samples)) * 0.9 }
        func quantize(_ x: Double, bits: Double) -> Double { Self.quantize(x, bits: bits, fractional: fractionalBits) }
        func bitwise(_ x: Double) -> Double {
            let clampedBits = min(max(Int(bits.rounded()), 1), 32)
            let levels = pow(2, Double(clampedBits - 1))
            let value = Int((min(max(x, -1), 1) * levels).rounded())
            // As in the kernel: only the sample's own magnitude bits of the mask apply.
            let applied = mask & ((1 << (clampedBits - 1)) - 1)
            let combined: Int
            switch operatorName {
            case "and": combined = value & applied
            case "or": combined = value | applied
            default: combined = value ^ applied
            }
            return min(max(Double(combined) / levels, -1), 1)
        }
        var output: [Double] = []
        var previous = input.first ?? 0
        var current = previous
        for (frame, source) in input.enumerated() {
            switch mode {
            case "bitReduction":
                output.append(quantize(source, bits: bits))
            case "bitwise":
                output.append(bitwise(source))
            case "downsampling", "sampleAndHold":
                let phase = frame % interval
                if phase == 0 { current = source }
                output.append(linear && mode == "downsampling"
                    ? previous + (current - previous) * (Double(phase) / Double(interval)) : current)
                if phase == 0 { previous = current }
            default: // classic
                let phase = frame % interval
                if phase == 0 {
                    previous = current
                    current = quantize(source, bits: bits)
                }
                output.append(linear ? previous + (current - previous) * (Double(phase) / Double(interval)) : current)
            }
        }
        return (input, output)
    }
}

/// The Resonator card's partials. Mirrors `ResonatorTuning.bands` in BakeGPU: fₙ = f₀ · n · √(1 + B·n²),
/// B = inharmonicity × 0.001, silent above 0.45 × the sample rate.
public enum ResonatorPlot {
    public static func partials(root: Double, fineCents: Double, inharmonicity: Double, bands: Int, sampleRate: Double) -> [Double] {
        let fundamental = root * pow(2, fineCents / 1_200)
        let stiffness = inharmonicity * 0.001
        return (1...max(bands, 1)).compactMap { number in
            let n = Double(number)
            let frequency = fundamental * n * (1 + stiffness * n * n).squareRoot()
            return frequency <= sampleRate * 0.45 ? frequency : nil
        }
    }
}

/// The Feedback card's ideal echo amplitudes, before damping. Echo zero is the input; each later
/// echo is multiplied by the linear feedback gain. Damping is shown as a simple per-echo spectral
/// brightness estimate so the picture stays pure maths and independent of a rendered signal.
public enum FeedbackPlot {
    public struct Echo: Equatable {
        public let time: Double
        public let amplitude: Double
        public let brightness: Double
    }

    public static func echoes(gainDecibels: Double, delayMilliseconds: Double, lowCut: Double, highCut: Double, count: Int = 8) -> [Echo] {
        let gain = pow(10, min(max(gainDecibels, -60), 6) / 20)
        let delay = max(delayMilliseconds, 0)
        let low = min(max(lowCut, 20), 2_000)
        let high = min(max(highCut, 1_000), 20_000)
        let rawBrightness = min(max(log2(high / low) / log2(20_000.0 / 20), 0), 1)
        let brightness = rawBrightness == 1 ? 1 : rawBrightness * 0.75
        return (0..<max(count, 1)).map { echo in
            Echo(time: Double(echo) * delay, amplitude: pow(gain, Double(echo)), brightness: brightness)
        }
    }
}

/// The Stretch card's analysis window.
public enum StretchPlot {
    public static func windowMilliseconds(fftSize: Int, sampleRate: Double) -> Double {
        sampleRate > 0 ? Double(fftSize) / sampleRate * 1_000 : 0
    }
}

/// The Envelope card's curve for a held gate. Mirrors the stage shapes in BakeDSP/Envelope.cpp:
/// each stage is a straight line ("linear") or a smoothstep ("exponential", as the kernel does it).
public enum EnvelopePlot {
    public struct Curve: Equatable {
        public let times: [Double]
        public let levels: [Double]
        /// Seconds from the start of the attack to the end of the release.
        public let duration: Double
        /// Where the sustain starts and ends, in seconds.
        public let sustainStart: Double
        public let sustainEnd: Double
    }

    public static func curve(
        attack: Double, decay: Double, sustain: Double, release: Double, timeScale: Double, shape: String, points: Int
    ) -> Curve {
        func seconds(_ value: Double) -> Double { min(max(value * min(max(timeScale, 0.1), 10), 0.001), 10) }
        let a = seconds(attack), d = seconds(decay), r = seconds(release)
        let level = min(max(sustain, 0), 1)
        // A held gate: show the sustain for a quarter as long as the rest, so it is visible without dominating.
        let hold = max(0.25 * (a + d + r), 0.01)
        let total = a + d + hold + r
        func shaped(_ progress: Double) -> Double {
            let p = min(max(progress, 0), 1)
            return shape == "linear" ? p : p * p * (3 - 2 * p)
        }
        func value(at t: Double) -> Double {
            if t < a { return shaped(t / a) }
            if t < a + d { return 1 + (level - 1) * shaped((t - a) / d) }
            if t < a + d + hold { return level }
            return level * (1 - shaped((t - a - d - hold) / r))
        }
        let count = max(points, 2)
        let times = (0..<count).map { total * Double($0) / Double(count - 1) }
        return Curve(times: times, levels: times.map(value(at:)), duration: total, sustainStart: a + d, sustainEnd: a + d + hold)
    }
}

/// The Quantizer card's staircase. Mirrors `renderQuantizer` in BakeDSP/Quantizer.cpp: the nearest note
/// of the scale within ±24 semitones, ties going down, as semitones / 24.
public enum QuantizerPlot {
    public static let scales = ["chromatic", "major", "minor", "pentatonic"]

    public static func quantize(scale: String, root: Int, x: Double) -> Double {
        let notes: Set<Int>
        switch scale {
        case "major": notes = [0, 2, 4, 5, 7, 9, 11]
        case "minor": notes = [0, 2, 3, 5, 7, 8, 10]
        case "pentatonic": notes = [0, 2, 4, 7, 9]
        default: notes = Set(0..<12)
        }
        let rootNote = ((root % 12) + 12) % 12
        func allowed(_ semitone: Int) -> Bool { notes.contains(((semitone - rootNote) % 12 + 12) % 12) }
        let semitones = min(max(x, -1), 1) * 24
        let floorNote = Int(semitones.rounded(.down))
        var below = floorNote
        while below >= -24 && !allowed(below) { below -= 1 }
        var above = floorNote + 1
        while above <= 24 && !allowed(above) { above += 1 }
        let belowFits = below >= -24
        let aboveFits = above <= 24
        var chosen = below
        if !belowFits || (aboveFits && Double(above) - semitones < semitones - Double(below)) { chosen = above }
        return Double(chosen) / 24
    }
}

extension FrequencyResponse {
    /// The Flanger's gain in dB at `frequency`, with its delay swept by the LFO (`lfo` 0…1: 0 = the
    /// longest delay, 1 = the shortest). Mirrors the delay line and feedback loop in BakeDSP/Flanger.cpp
    /// with ideal fractional delay: output = dry + Mix · D / (1 − g · Damping · D), D = z⁻ᵈ.
    public static func flangerDecibels(
        delayMilliseconds: Double, depth: Double, lfo: Double, feedback: Double, negativeFeedback: Bool, damping: Double,
        mix: Double, at frequency: Double, sampleRate: Double = 48_000
    ) -> Double {
        let longest = min(max(delayMilliseconds * sampleRate / 1_000, 1), 4_096)
        let delay = max(longest * (1 - min(max(depth, 0), 1) * min(max(lfo, 0), 1)), 1)
        let omega = 2 * Double.pi * frequency / sampleRate
        let delayed = Complex.unit(angle: -omega * delay)
        let z1 = Complex.unit(angle: -omega)
        let damp = min(max(damping, 0), 0.95)
        let lowpass = Complex(1 - damp, 0) / (Complex(1, 0) + z1 * -damp)
        let gain = min(max(feedback, 0), 0.95) * (negativeFeedback ? -1 : 1)
        let wet = delayed / (Complex(1, 0) + (lowpass * delayed) * -gain)
        let total = Complex(1, 0) + wet * min(max(mix, 0), 1)
        return 20 * log10(max(total.magnitude, 1e-9))
    }

    /// The Flanger's LFO position (0…1) at `time` seconds, as the kernel computes it: `0.5 + 0.5·sin(2π · rate · time)`.
    public static func flangerSweep(rate: Double, at time: Double) -> Double {
        0.5 + 0.5 * sin(2 * Double.pi * min(max(rate, 0.01), 20) * time)
    }
}

/// The Vocoder card's bands. Mirrors `vocoderBandCenters` in BakeDSP/Vocoder.cpp: centres spaced
/// evenly on the chosen frequency axis from 80 Hz to 16 kHz (or 0.45 × the sample rate if lower).
public enum VocoderPlot {
    public static func warp(_ hertz: Double, spacing: String) -> Double {
        switch spacing {
        case "linear": return hertz
        case "bark": return 13 * atan(0.00076 * hertz) + 3.5 * atan((hertz / 7_500) * (hertz / 7_500))
        case "mel": return 2_595 * log10(1 + hertz / 700)
        default: return log(max(hertz, 1))
        }
    }

    private static func unwarp(_ value: Double, spacing: String) -> Double {
        switch spacing {
        case "linear": return value
        case "mel": return 700 * (pow(10, value / 2_595) - 1)
        case "bark":
            var (low, high) = (0.0, 40_000.0)
            for _ in 0..<80 {
                let middle = 0.5 * (low + high)
                if warp(middle, spacing: spacing) < value { low = middle } else { high = middle }
            }
            return 0.5 * (low + high)
        default: return exp(value)
        }
    }

    public static func centres(bands: Int, spacing: String, sampleRate: Double) -> [Double] {
        let count = min(max(bands, 16), 256)
        let low = warp(80, spacing: spacing)
        let span = warp(min(16_000, 0.45 * sampleRate), spacing: spacing) - low
        return (0..<count).map { unwarp(low + span * Double($0) / Double(count - 1), spacing: spacing) }
    }
}

/// The Math card's curve: the result for an `a` from −1 to +1 with `b` held at a fixed value.
/// Mirrors `apply` and `renderMath` in BakeDSP/Math.cpp.
public enum MathPlot {
    public static func apply(operatorName: String, a: Double, b: Double, scale: Double, minimum: Double, maximum: Double) -> Double {
        let raw: Double
        switch operatorName {
        case "subtract": raw = a - b
        case "multiply": raw = a * b
        case "divide": raw = abs(b) < 1e-6 ? 0 : a / b
        case "abs": raw = abs(a)
        case "invert": raw = -a
        case "modulo": raw = abs(b) < 1e-6 ? 0 : fmod(a, b)
        default: raw = a + b
        }
        let low = min(minimum, maximum)
        let high = max(minimum, maximum)
        let value = raw * scale
        return value.isFinite ? min(max(value, low), high) : min(max(0, low), high)
    }
}

/// The Chorus card's voices: each one's delay in milliseconds, `cycles` drift cycles in. Mirrors the
/// delay maths in `renderChorus` (BakeDSP/Chorus.cpp): a resting delay of 12 ms, fanned ±6 ms by Spread,
/// plus a wobble deep enough to bend the pitch by Detune cents.
public enum ChorusPlot {
    public static func voiceDelays(voices: Int, detuneCents: Double, spread: Double, driftRate: Double, cycles: Double) -> [Double] {
        let count = min(max(voices, 2), 8)
        let rate = min(max(driftRate, 0.01), 10)
        let depth = (pow(2, detuneCents / 1_200) - 1) * 1_000 / (2 * Double.pi * rate)
        return (0..<count).map { voice in
            let position = Double(voice) / Double(count)
            let resting = 12 + 12 * 0.5 * min(max(spread, 0), 1) * (2 * position - 1)
            return resting + depth * sin(2 * Double.pi * (cycles + position))
        }
    }
}

extension ChorusPlot {
    /// The swarm's most voices and Reach, as BakeDSP/Chorus.h.
    public static let maximumSwarmVoices = 1_024
    public static let maximumReachMilliseconds = 5_000.0

    /// Whether the Chorus renders as the swarm (`renderChorusSwarm`): more than 8 voices, or any Reach.
    public static func isSwarm(voices: Int, reachMilliseconds: Double) -> Bool { voices > 8 || reachMilliseconds > 0 }

    /// Uniform in [0, 1) from a voice and a set, as `hashed` in Chorus.cpp (set 0 is shared by every channel).
    static func hashed(voice: Int, set: Int) -> Double {
        var value = UInt32(truncatingIfNeeded: voice) &* 0x9e37_79b1 ^ (UInt32(truncatingIfNeeded: set) &+ 1) &* 0x85eb_ca6b ^ 0x5bd1_e995
        value ^= value >> 16
        value = value &* 0x7feb_352d
        value ^= value >> 15
        value = value &* 0x846c_a68b
        value ^= value >> 16
        return Double(value >> 8) / 16_777_216
    }

    /// Every swarm voice's delay in milliseconds for the left channel, `cycles` drift cycles in. Mirrors
    /// `buildChorusSwarmTable` and `renderChorusSwarm`: the 12 ms resting delay, each voice fanned by Spread and
    /// pushed by its own random share of ±Reach (negative delays read the input's future), plus the drift wobble.
    public static func swarmDelays(
        voices: Int, detuneCents: Double, spread: Double, driftRate: Double, reachMilliseconds: Double, cycles: Double
    ) -> [Double] {
        let count = min(max(voices, 1), maximumSwarmVoices)
        let rate = min(max(driftRate, 0.01), 10)
        let reach = min(max(reachMilliseconds, 0), maximumReachMilliseconds)
        let amount = min(max(spread, 0), 1)
        let depth = (pow(2, detuneCents / 1_200) - 1) * 1_000 / (2 * Double.pi * rate)
        return (0..<count).map { voice in
            let position = Double(voice) / Double(count)
            let fan = 12 * 0.5 * (2 * position - 1)
            let pushed = reach * (2 * hashed(voice: voice, set: 0) - 1)
            return 12 + amount * (fan + pushed) + depth * sin(2 * Double.pi * (cycles + position))
        }
    }
}

/// The Spectral Resynthesis card: the tilt as a gain line about 1 kHz, and how much sine and noise play.
/// Mirrors `partialGain` and the balance gains in `resynthesisRender` (BakeDSP/Resynthesis.cpp).
public enum ResynthesisPlot {
    /// Gain in dB at `frequency` for a tilt in dB per octave.
    public static func tiltDecibels(frequency: Double, tilt: Double) -> Double {
        frequency > 0 ? tilt * log2(frequency / 1_000) : 0
    }

    /// Sine and noise levels (0…1) for a balance of 0 (sines only), 0.5 (as analysed) or 1 (noise only).
    public static func levels(balance: Double) -> (sine: Double, noise: Double) {
        let b = min(max(balance, 0), 1)
        return (min(1, 2 * (1 - b)), min(1, 2 * b))
    }
}

public enum LogicPlot {
    /// Where A switches: high above `rise`, low below `fall` (a Schmitt trigger; the same with no hysteresis).
    public static func edges(threshold: Double, hysteresis: Double) -> (rise: Double, fall: Double) {
        let margin = max(hysteresis, 0)
        return (threshold + margin, threshold - margin)
    }

    /// The output for A and B already compared, as the kernel combines them.
    public static func gate(_ operatorName: String, a: Bool, b: Bool) -> Bool {
        switch operatorName {
        case "and": a && b
        case "or": a || b
        case "xor": a != b
        case "not": !a
        default: a
        }
    }
}

public enum GainVCAPlot {
    /// The level a control value sets: VCA maps −1…1 onto 0…1, ring mod multiplies by it directly.
    public static func multiplier(ringMod: Bool, gainDecibels: Double, control: Double) -> Double {
        let gain = pow(10, gainDecibels / 20)
        return gain * (ringMod ? control : min(max((control + 1) / 2, 0), 1))
    }
}
