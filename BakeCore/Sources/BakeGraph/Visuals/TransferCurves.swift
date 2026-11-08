import Foundation

/// What the card plots for the shaping nodes: the node's input/output curve for a signal in −1…1.
/// These mirror the C++ kernels (`waveshaperTransfer`, `wavefolderTransfer` in BakeDSP) formula for
/// formula; `TransferCurveTests` in BakeRenderTests renders both and compares. Mix is not included,
/// so a view can blend it in itself.
public enum TransferCurves {
    public static let waveshaperCurves = ["tanh", "arctan", "softsign", "sine", "cubic", "hardClip", "asymmetric", "chebyshev"]

    /// The Waveshaper at input `x`: Drive (`intensity`, 0…1) sets both how hard the curve is driven
    /// (1× to 16×) and how much of it replaces the dry signal; `bias` (−1…1) moves the operating point.
    public static func waveshaper(curve: String, x: Double, intensity: Double, bias: Double) -> Double {
        let amount = min(max(intensity, 0), 1)
        let drive = 1 + 15 * amount
        let offset = 2 * min(max(bias, -1), 1)
        let shaped = (curveValue(curve, drive * x + offset) - curveValue(curve, offset)) / curveNormal(curve, drive: drive)
        return x + amount * (shaped - x)
    }

    private static func curveValue(_ curve: String, _ u: Double) -> Double {
        switch curve {
        case "arctan": return (2 / .pi) * atan(u * (.pi / 2))
        case "softsign": return u / (1 + abs(u))
        case "sine": return sin(u)
        case "cubic":
            let v = min(max(u, -1), 1)
            return 1.5 * v - 0.5 * v * v * v
        case "hardClip": return min(max(u, -1), 1)
        case "asymmetric": return u >= 0 ? tanh(u) : 0.6 * tanh(u / 0.6)
        case "chebyshev":
            let v = min(max(u, -1), 1)
            let v2 = v * v
            let t3 = v * (4 * v2 - 3)
            let t5 = v * (16 * v2 * v2 - 20 * v2 + 5)
            return (v + 0.5 * t3 + 0.25 * t5) / 1.75
        default: return tanh(u)
        }
    }

    /// What the curve reaches at full drive, so ±1 in gives ±1 out (curves that already do are left alone).
    private static func curveNormal(_ curve: String, drive: Double) -> Double {
        switch curve {
        case "tanh", "arctan", "softsign", "asymmetric": return curveValue(curve, drive)
        default: return 1
        }
    }

    /// The Wavefolder at input `x` (before Mix).
    public static func wavefolder(shape: String, x: Double, fold: Double, symmetry: Double, stages: Int, saturation: Double) -> Double {
        let amount = min(max(fold, 0), 1)
        let bias = min(max(symmetry, -1), 1) * amount
        var wet = x * (1 + 15 * amount) + bias
        for stage in 0..<min(max(stages, 1), 8) {
            if stage > 0 { wet *= 1 + amount }
            wet = shape == "sine" ? sin(.pi / 2 * wet) : foldTriangle(wet)
        }
        let saturate = min(max(saturation, 0), 1)
        wet += saturate * (tanh(2 * wet) - wet)
        return min(max(wet, -1), 1)
    }

    private static func foldTriangle(_ value: Double) -> Double {
        var phase = (value + 1).truncatingRemainder(dividingBy: 4)
        if phase < 0 { phase += 4 }
        return phase <= 2 ? phase - 1 : 3 - phase
    }
}
