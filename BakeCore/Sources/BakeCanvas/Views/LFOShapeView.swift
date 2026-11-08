import SwiftUI

/// The LFO's shapes exactly as the C++ kernel renders them (BakeDSP/LFO.cpp `shapeValue`): every
/// shape starts at 0 and rises, square starts at +1, and sample & hold takes the next value of the
/// kernel's seeded LCG at the start of each cycle.
enum LFOShape {
    /// `cycles` counts from the start of the render, including the phase offset (phase° / 360).
    static func value(_ shape: String, at cycles: Double, seed: Int) -> Double {
        let p = cycles - cycles.rounded(.down)
        switch shape {
        case "triangle": return p < 0.25 ? 4 * p : (p < 0.75 ? 2 - 4 * p : 4 * p - 4)
        case "saw": return p < 0.5 ? 2 * p : 2 * p - 2
        case "square": return p < 0.5 ? 1 : -1
        case "sampleAndHold": return held(cycle: max(Int(cycles.rounded(.down)), 0), seed: seed)
        default: return sin(2 * .pi * p)
        }
    }

    /// The value held during `cycle` (0 = the first): one LCG step per cycle, as in the kernel.
    private static func held(cycle: Int, seed: Int) -> Double {
        var state = UInt32(truncatingIfNeeded: seed)
        var value: Float = 0
        for _ in 0...cycle {
            state = state &* 1_664_525 &+ 1_013_904_223
            value = Float(state >> 8) / 16_777_216 * 2 - 1
        }
        return Double(value)
    }
}

/// Two cycles of the LFO's shape, scaled by depth and starting at its phase. A dot runs along it at
/// the LFO's own rate, so you can watch what a bake will do to whatever it is wired to.
/// Over Length draws all `cycles` cycles instead, the whole of what it feeds, and the dot crosses
/// that once every four seconds: its real speed depends on a length the card doesn't know.
struct LFOShapeView: View {
    let shape: String
    let depth: Double
    let phase: Double
    let seed: Int
    let rate: Double
    var overLength: Bool = false
    var cycles: Double = 1

    /// Cycles drawn across the plot.
    var shownCycles: Double { overLength ? cycles : 2 }

    var body: some View {
        MovingPlot { time in
            plot(time: time)
        }
        .frame(height: 36)
        .accessibilityLabel("LFO shape")
    }

    private func plot(time: Double) -> some View {
        Canvas { context, size in
            let start = phase / 360
            var path = Path()
            let steps = min(max(160, Int(shownCycles * 32)), 4_096)
            for step in 0...steps {
                let x = Double(step) / Double(steps)
                let y = LFOShape.value(shape, at: start + x * shownCycles, seed: seed) * depth
                let point = CGPoint(x: x * size.width, y: (1 - y) / 2 * size.height)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: size.height / 2))
            axis.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(axis, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
            context.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

            // Cycles since the start of the bake, wrapped to the two cycles on screen so the dot
            // always sits on the curve.
            let wrapped = overLength
                ? (time / 4).truncatingRemainder(dividingBy: 1) * shownCycles
                : (time * rate).truncatingRemainder(dividingBy: 2)
            let y = LFOShape.value(shape, at: start + wrapped, seed: seed) * depth
            let dot = CGPoint(x: wrapped / shownCycles * size.width, y: (1 - y) / 2 * size.height)
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .style(.tint))
        }
    }
}
