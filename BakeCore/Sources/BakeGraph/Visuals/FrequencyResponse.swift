import Foundation

/// What the card plots for the filtering nodes: gain against frequency. These mirror the C++ kernels
/// (`biquadCoefficients` in Filters.cpp, the all-pass chain and feedback loop in Phaser.cpp);
/// `FrequencyResponseTests` in BakeRenderTests measures the real kernels and compares.
public enum FrequencyResponse {
    /// The Filters node's gain in dB at `frequency`: an RBJ biquad, `sections` of them in a row (12 dB/oct each).
    public static func filterDecibels(
        type: String, cutoff: Double, q: Double, sections: Int, at frequency: Double, sampleRate: Double = 48_000
    ) -> Double {
        let w0 = 2 * Double.pi * min(cutoff, 0.49 * sampleRate) / sampleRate
        let cosine = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        switch type {
        case "highpass": b0 = (1 + cosine) / 2; b1 = -(1 + cosine); b2 = b0
        case "bandpass": b0 = alpha; b1 = 0; b2 = -alpha
        case "notch": b0 = 1; b1 = -2 * cosine; b2 = 1
        default: b0 = (1 - cosine) / 2; b1 = 1 - cosine; b2 = b0
        }
        let z1 = Complex.unit(angle: -2 * Double.pi * frequency / sampleRate)   // z⁻¹
        let z2 = z1 * z1
        let numerator = Complex(b0 / a0, 0) + z1 * (b1 / a0) + z2 * (b2 / a0)
        let denominator = Complex(1, 0) + z1 * (-2 * cosine / a0) + z2 * ((1 - alpha) / a0)
        let magnitude = (numerator / denominator).magnitude
        return Double(sections) * decibels(magnitude)
    }

    /// One RBJ biquad's complex response at `frequency` (the Filters node's section, with the phase kept).
    static func biquadResponse(type: String, cutoff: Double, q: Double, at frequency: Double, sampleRate: Double = 48_000) -> Complex {
        let w0 = 2 * Double.pi * min(cutoff, 0.49 * sampleRate) / sampleRate
        let cosine = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        switch type {
        case "highpass": b0 = (1 + cosine) / 2; b1 = -(1 + cosine); b2 = b0
        case "bandpass": b0 = alpha; b1 = 0; b2 = -alpha
        case "notch": b0 = 1; b1 = -2 * cosine; b2 = 1
        default: b0 = (1 - cosine) / 2; b1 = 1 - cosine; b2 = b0
        }
        let z1 = Complex.unit(angle: -2 * Double.pi * frequency / sampleRate)
        let z2 = z1 * z1
        let numerator = Complex(b0 / a0, 0) + z1 * (b1 / a0) + z2 * (b2 / a0)
        let denominator = Complex(1, 0) + z1 * (-2 * cosine / a0) + z2 * ((1 - alpha) / a0)
        return numerator / denominator
    }

    /// The two path cutoffs of the Dual Filter, in Hz: Alpha above the Cutoff by half the Spread, Beta below, each moved by
    /// the LFO (`lfo` is its value, −1…1; Inverted sends Beta the other way). Mirrors `coefficientsAt` in DualFilter.cpp.
    public static func dualFilterCutoffs(
        cutoff: Double, spread: Double, lfoDepth: Double, inverted: Bool, lfo: Double, sampleRate: Double = 48_000
    ) -> (alpha: Double, beta: Double) {
        let highest = min(20_000, 0.45 * sampleRate)
        let half = spread / 2
        let depth = 2 * lfoDepth
        return (
            min(max(cutoff * pow(2, half + depth * lfo), 20), highest),
            min(max(cutoff * pow(2, -half + depth * (inverted ? -lfo : lfo)), 20), highest)
        )
    }

    /// The Dual Filter's gain in dB at `frequency`: each path is `sections` biquads in a row, Morph crossfades them as
    /// cos / sin of a quarter turn, and Mix blends the result with the dry signal. Minimum phase adds the paths with
    /// their phases; Zero phase runs each path forward and back, so the paths are their squared magnitudes. Drive, a
    /// nonlinear stage, is not part of the picture.
    public static func dualFilterDecibels(
        alphaType: String, betaType: String, cutoffs: (alpha: Double, beta: Double), q: Double, morph: Double,
        sections: Int, zeroPhase: Bool, mix: Double, at frequency: Double, sampleRate: Double = 48_000
    ) -> Double {
        func path(_ type: String, _ cutoff: Double) -> Complex {
            let section = biquadResponse(type: type, cutoff: cutoff, q: q, at: frequency, sampleRate: sampleRate)
            var response = Complex(1, 0)
            for _ in 0..<max(sections, 1) { response = response * section }
            return zeroPhase ? Complex(response.re * response.re + response.im * response.im, 0) : response
        }
        let angle = min(max(morph, 0), 1) * Double.pi / 2
        let wet = path(alphaType, cutoffs.alpha) * cos(angle) + path(betaType, cutoffs.beta) * sin(angle)
        let blend = min(max(mix, 0), 1)
        let total = wet * blend + Complex(1 - blend, 0)
        return decibels(total.magnitude)
    }

    /// How wide the linear-phase filter's edge is, in Hz: 1 dB down to 90 dB down. Mirrors
    /// `linearPhaseTransitionHz` in BakeDSP/LinearPhase.cpp.
    public static func linearPhaseTransitionHertz(taps: Int, sampleRate: Double = 48_000) -> Double {
        let count = max(min(taps, 131_073), 65) | 1
        return 0.68 * (100 - 7.95) / (2.285 * Double(count - 1)) / (2 * Double.pi) * sampleRate
    }

    /// The linear-phase Filters node's gain in dB at `frequency`: a windowed-sinc low-pass is half
    /// amplitude (6 dB down) at its cutoff and falls to about −100 dB over the edge, drawn here as a
    /// raised-cosine taper of that width. High-pass, band-pass and notch are built from low-passes
    /// the way the kernel is (one minus, or a difference), and are real, so they add and subtract
    /// as plain amplitudes. The plot checks against the kernel in `PlotMathTests`.
    public static func linearPhaseDecibels(
        type: String, cutoff: Double, q: Double, taps: Int, at frequency: Double, sampleRate: Double = 48_000
    ) -> Double {
        // The taper runs from 0.57 of its half-width below the cutoff's −1 dB point to just past the −90 dB point.
        let half = linearPhaseTransitionHertz(taps: taps, sampleRate: sampleRate) / 1.566
        func lowpass(_ edge: Double) -> Double {
            let t = (frequency - (edge - half)) / (2 * half)
            if t <= 0 { return 1 }
            if t >= 1 { return 0 }
            return 0.5 * (1 + cos(Double.pi * t))
        }
        let top = 0.49 * sampleRate
        let middle = min(max(cutoff, 10), top)
        let bandwidth = 2 * asinh(1 / (2 * min(max(q, 0.1), 20))) / log(2.0)
        let low = min(max(middle * pow(2, -bandwidth / 2), 5), top)
        let high = min(max(middle * pow(2, bandwidth / 2), 5), top)
        let amplitude: Double
        switch type {
        case "highpass": amplitude = 1 - lowpass(middle)
        case "bandpass": amplitude = lowpass(high) - lowpass(low)
        case "notch": amplitude = 1 - (lowpass(high) - lowpass(low))
        default: amplitude = lowpass(middle)
        }
        return 20 * log10(max(abs(amplitude), 1e-6))
    }

    /// The Phaser's gain in dB at `frequency`, with its centre swept `sweepOctaves` away from `center`
    /// (the LFO's position; 0 = resting). Includes the feedback loop, its DC blocker, and Mix.
    public static func phaserDecibels(
        center: Double, width: Double, stages: Int, feedback: Double, mix: Double, sweepOctaves: Double = 0,
        at frequency: Double, sampleRate: Double = 48_000
    ) -> Double {
        let stageCount = min(max(stages, 2), 64)
        let octaves = min(max(width, 0.25), 4)
        let centerHz = min(max(center * pow(2, sweepOctaves), 20), sampleRate * 0.45)
        let z1 = Complex.unit(angle: -2 * Double.pi * frequency / sampleRate)

        var allPass = Complex(1, 0)
        for stage in 0..<stageCount {
            let position = Double(stage) / Double(stageCount - 1)
            let stageHz = min(max(centerHz * pow(2, (position - 0.5) * octaves), 10), sampleRate * 0.45)
            let tangent = tan(Double.pi * stageHz / sampleRate)
            let c = (1 - tangent) / (1 + tangent)
            allPass = allPass * ((Complex(-c, 0) + z1) / (Complex(1, 0) + z1 * (-c)))
        }
        // wet = A · (dry + r · DC-blocked, one-sample-delayed wet)  →  W = A / (1 − r · A · B · z⁻¹)
        let r = min(max(feedback, -0.95), 0.95)
        let blocker = (Complex(1, 0) + z1 * -1) / (Complex(1, 0) + z1 * -0.995)
        let wet = allPass / (Complex(1, 0) + (allPass * blocker * z1) * -r)
        let blend = min(max(mix, 0), 1)
        let total = Complex(1 - blend, 0) + wet * blend
        return decibels(total.magnitude)
    }

    /// The sweep position in octaves for the Phaser's LFO at `time` seconds, as the kernel does it:
    /// `depth · sin(2π · rate · time) · width / 2`.
    public static func phaserSweepOctaves(depth: Double, width: Double, rate: Double, at time: Double) -> Double {
        min(max(depth, 0), 1) * sin(2 * Double.pi * rate * time) * min(max(width, 0.25), 4) * 0.5
    }

    private static func decibels(_ magnitude: Double) -> Double { 20 * log10(max(magnitude, 1e-9)) }
}

/// Just enough complex arithmetic for the responses above.
struct Complex {
    var re: Double
    var im: Double

    init(_ re: Double, _ im: Double) { self.re = re; self.im = im }

    static func unit(angle: Double) -> Complex { Complex(cos(angle), sin(angle)) }

    var magnitude: Double { (re * re + im * im).squareRoot() }

    static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    static func * (a: Complex, b: Complex) -> Complex { Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    static func * (a: Complex, s: Double) -> Complex { Complex(a.re * s, a.im * s) }
    static func / (a: Complex, b: Complex) -> Complex {
        let d = b.re * b.re + b.im * b.im
        return Complex((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
}
