import BakeGraph
import SwiftUI

/// Where modulation takes a parameter, computed the way the renderer does (BakeDSP's
/// `ParameterSignal`): linear numbers move by trim × modulation × the range, exponential ones by
/// that many range-spans in octaves, and choices by that many options (rounded). Values clamp to the
/// parameter's range.
public struct ModulationRange: Equatable, Sendable {
    public let parameter: ParameterDefinition
    /// The knob value (a choice's option index).
    public let base: Double
    /// The Page 2 trim, −1…+1.
    public let trim: Double

    public init(parameter: ParameterDefinition, value: ParameterValue?, trim: Double) {
        self.parameter = parameter
        self.trim = trim
        switch parameter.kind {
        case .number(_, let defaultValue, _):
            base = value?.numberValue ?? defaultValue
        case .choice(let options, let defaultValue):
            let current: String = if case .choice(let choice)? = value { choice } else { defaultValue }
            base = Double(options.firstIndex(of: current) ?? 0)
        case .text:
            base = 0
        }
    }

    /// The parameter's value while the modulation signal reads `modulation`.
    public func value(at modulation: Double) -> Double {
        let amount = trim * modulation
        switch parameter.kind {
        case .number(let range, _, _):
            let moved = parameter.modulationScale == .exponential && range.lowerBound > 0
                ? base * pow(range.upperBound / range.lowerBound, amount)
                : base + amount * (range.upperBound - range.lowerBound)
            let clamped = min(max(moved, range.lowerBound), range.upperBound)
            return parameter.isInteger ? clamped.rounded() : clamped
        case .choice(let options, _):
            let last = Double(max(options.count - 1, 0))
            return min(max((base + amount * last).rounded(), 0), last)
        case .text:
            return base
        }
    }

    /// Everything a signal between −1 and +1 can reach, before any bake.
    public var possible: ClosedRange<Double> {
        let ends = [value(at: -1), value(at: 0), value(at: 1)]
        return ends.min()!...ends.max()!
    }

    /// What a baked modulation trace actually reached; nil for an empty trace.
    public func swept(_ trace: [Float]) -> ClosedRange<Double>? {
        let values = trace.filter(\.isFinite).map { value(at: Double($0)) }
        guard let low = values.min(), let high = values.max() else { return nil }
        return low...high
    }
}

/// A thin lane under a modulated control: a teal band over where modulation can take it (or, after a
/// bake, where it went), and a dot replaying the last bake's first seconds on a loop. Choices show
/// one segment per option instead, the reachable ones tinted and the current one lit.
struct ModulationLane: View {
    let range: ModulationRange
    /// The modulation signal from the last bake (`NodeSummary.detail`), or empty before one.
    let trace: [Float]
    let mapping: SliderMapping?
    /// The slider's track runs inside its thumb radius; the lane lines up with it.
    private let inset: CGFloat = 7

    var body: some View {
        let swept = range.swept(trace)
        let band = swept ?? range.possible
        MovingPlot { time in
            Canvas { context, size in
                if case .choice(let options, _) = range.parameter.kind {
                    drawChoices(options.count, band: band, current: currentValue(time), in: context, size: size)
                } else {
                    drawNumber(band: band, baked: swept != nil, current: currentValue(time), in: context, size: size)
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityIdentifier("modulation.\(range.parameter.id)")
        // In the label: macOS reports no value for a plain element like this one.
        .accessibilityLabel("\(range.parameter.name) modulation \(swept == nil ? "can reach" : "moved through") \(describe(band))")
    }

    /// The value the trace shows `time` seconds into its loop; nil before a bake.
    private func currentValue(_ time: Double) -> Double? {
        guard !trace.isEmpty else { return nil }
        let loop = Double(trace.count) / NodeSummary.detailRate
        let index = min(Int((time.truncatingRemainder(dividingBy: max(loop, 0.001))) * NodeSummary.detailRate), trace.count - 1)
        let sample = trace[max(index, 0)]
        return sample.isFinite ? range.value(at: Double(sample)) : nil
    }

    private func position(_ value: Double) -> CGFloat {
        guard case .number(let span, _, _) = range.parameter.kind else { return 0 }
        let fraction = mapping?.position(for: value) ?? (value - span.lowerBound) / max(span.upperBound - span.lowerBound, 1e-12)
        return CGFloat(min(max(fraction, 0), 1))
    }

    private func drawNumber(band: ClosedRange<Double>, baked: Bool, current: Double?, in context: GraphicsContext, size: CGSize) {
        let width = size.width - 2 * inset
        let low = inset + position(band.lowerBound) * width
        let high = inset + position(band.upperBound) * width
        let lane = CGRect(x: low, y: size.height / 2 - 1.5, width: max(high - low, 2), height: 3)
        context.fill(Path(roundedRect: lane, cornerRadius: 1.5), with: .color(.teal.opacity(baked ? 0.7 : 0.35)))
        if let current {
            let x = inset + position(current) * width
            context.fill(Path(ellipseIn: CGRect(x: x - 3, y: size.height / 2 - 3, width: 6, height: 6)), with: .color(.teal))
        }
    }

    private func drawChoices(_ count: Int, band: ClosedRange<Double>, current: Double?, in context: GraphicsContext, size: CGSize) {
        guard count > 0 else { return }
        let gap: CGFloat = 2
        let cell = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        for option in 0..<count {
            let rect = CGRect(x: CGFloat(option) * (cell + gap), y: 1, width: cell, height: size.height - 2)
            let reachable = band.contains(Double(option))
            let lit = current.map { Int($0) == option } ?? false
            let opacity = lit ? 1.0 : reachable ? 0.35 : 0.08
            context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.teal.opacity(opacity)))
        }
    }

    private func describe(_ band: ClosedRange<Double>) -> String {
        switch range.parameter.kind {
        case .number(_, _, let unit):
            "\(ParameterFormat.string(band.lowerBound, unit: unit)) to \(ParameterFormat.string(band.upperBound, unit: unit))"
        case .choice(let options, _):
            "\(options[Int(band.lowerBound)]) to \(options[Int(band.upperBound)])"
        case .text:
            ""
        }
    }
}
