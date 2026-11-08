import BakeGraph
import Foundation
import SwiftUI

/// What a node produced the last time a bake ran it: its waveform and, for audio, a spectrogram
/// (time across, pitch up). Because a bake is offline, this is how you see a node's work. It goes
/// dim when the node, or anything feeding it, has changed since.
struct RenderedOutputView: View {
    let summary: NodeSummary
    let isStale: Bool
    /// Control only: detail points where a trigger input banged (the Envelope's ticks).
    var triggerTicks: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Last bake").font(.caption2).foregroundStyle(.secondary)
            EnvelopeView(summary: summary, triggerTicks: triggerTicks)
                .frame(height: summary.isControl ? 40 : 30)
            if let spectrogram = summary.spectrogram, let image = SpectrogramImages.image(for: spectrogram) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityHidden(true)
            }
            HStack {
                Text(RenderedOutputCaption.text(for: summary))
                Spacer()
                if isStale { Text("Out of date").foregroundStyle(.orange) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .opacity(isStale ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last bake: \(RenderedOutputCaption.text(for: summary))\(isStale ? ", out of date" : "")")
    }
}

/// Spectrogram pictures, made once per spectrogram: a card redraws often (pans, wire drags), and a
/// fresh image each time is wasted work and can show for a frame as a jump.
@MainActor
enum SpectrogramImages {
    private static var cache: [Spectrogram: CGImage] = [:]

    static func image(for spectrogram: Spectrogram) -> CGImage? {
        if let cached = cache[spectrogram] { return cached }
        guard let image = spectrogram.image() else { return nil }
        // Every card's last bake fits many times over; old bakes are simply dropped.
        if cache.count >= 512 { cache.removeAll() }
        cache[spectrogram] = image
        return image
    }
}

/// The one line under a rendered picture.
enum RenderedOutputCaption {
    static func text(for summary: NodeSummary) -> String {
        let length = ParameterFormat.duration(summary.seconds)
        if summary.isControl {
            let low = summary.minimums.min() ?? 0
            let high = summary.maximums.max() ?? 0
            let shown = summary.detail.isEmpty ? "" : " · first \(Int(NodeSummary.detailSeconds)) s"
            return "\(length) · control · \(number(Double(low)))…\(number(Double(high)))\(shown)"
        }
        let channels = summary.channels == 1 ? "mono" : summary.channels == 2 ? "stereo" : "\(summary.channels) ch"
        return "\(length) · \(channels) · peak \(decibels(summary.peak))"
    }

    static func decibels(_ peak: Float) -> String {
        guard peak > 0 else { return "−∞ dB" }
        let value = 20 * log10(Double(peak))
        return "\(value < 0 ? "−" : "+")\(String(format: "%.1f", abs(value))) dB"
    }

    private static func number(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// What a control signal's "Last bake" shows per slice: its whole range, lowest to highest. A busy
/// signal (Clock bangs, a fast Envelope) fills its range; a slow one (an LFO slower than a slice)
/// narrows to a trace of its shape. Drawing the midpoint instead flattened a long Clock bake to 0.5.
enum ControlBand {
    struct Slice: Equatable {
        let low: Float
        let high: Float
    }

    static func slices(of summary: NodeSummary) -> [Slice] {
        zip(summary.minimums, summary.maximums).map { Slice(low: min($0, $1), high: max($0, $1)) }
    }
}

/// The last-bake summaries of what is wired into a card's input pins, so Math can draw A and B
/// and the Envelope its triggers. A wire finds its own output pin's summary in `outputs`; failing
/// that, a node's summary (its first output) counts only for a wire leaving that output.
enum CardInputs {
    static func summaries(
        feeding node: Node, in project: ProjectFile, from summaries: [NodeID: NodeSummary], outputs: [PinRef: NodeSummary] = [:]
    ) -> [PinID: NodeSummary] {
        var result: [PinID: NodeSummary] = [:]
        for edge in project.edges where edge.to.node == node.id {
            if let summary = outputs[edge.from] {
                result[edge.to.pin] = summary
                continue
            }
            guard let source = project.node(edge.from.node),
                  NodeCatalog.pins(of: source, in: project).first(where: { $0.direction == .output })?.id == edge.from.pin,
                  let summary = summaries[source.id] else { continue }
            result[edge.to.pin] = summary
        }
        return result
    }

    /// A node's own outputs' summaries, by pin.
    static func outputs(of node: Node, from outputs: [PinRef: NodeSummary]) -> [PinID: NodeSummary] {
        var result: [PinID: NodeSummary] = [:]
        for (pin, summary) in outputs where pin.node == node.id {
            result[pin.pin] = summary
        }
        return result
    }
}

/// Reading a control's detail trace (see `NodeSummary.detailTrace`).
enum ControlTrace {
    /// Points where a bang starts: the signal rises above 0.5 (the bang rule).
    static func rises(_ detail: [Float]) -> [Int] {
        detail.indices.filter { detail[$0] > 0.5 && ($0 == 0 || detail[$0 - 1] <= 0.5) }
    }

    /// Draws traces over the detail span (`NodeSummary.detailSeconds`), all on one scale: ±1, or
    /// wider if any of them goes further. Each trace is (values, style, line width).
    static func draw(_ traces: [([Float], GraphicsContext.Shading, CGFloat)], ticks: [Int] = [], in context: GraphicsContext, size: CGSize) {
        let points = Int(NodeSummary.detailSeconds * NodeSummary.detailRate)
        let range = max(traces.flatMap(\.0).map { Double(abs($0)) }.max() ?? 1, 1)
        func x(_ index: Int) -> CGFloat { CGFloat(index) / CGFloat(max(points - 1, 1)) * size.width }
        func y(_ value: Float) -> CGFloat { (1 - CGFloat(Double(value) / range)) / 2 * size.height }
        PlotLine.draw(context, from: CGPoint(x: 0, y: size.height / 2), to: CGPoint(x: size.width, y: size.height / 2))
        for tick in ticks {
            var mark = Path()
            mark.move(to: CGPoint(x: x(tick), y: size.height))
            mark.addLine(to: CGPoint(x: x(tick), y: size.height * 0.7))
            context.stroke(mark, with: .color(.secondary), lineWidth: 1)
        }
        for (values, style, width) in traces where !values.isEmpty {
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: x(index), y: y(value))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: style, style: StrokeStyle(lineWidth: width, lineJoin: .round))
        }
    }
}

/// The waveform: filled between each slice's lowest and highest sample, with the RMS inside. A
/// control signal is its range band instead (see `ControlBand`).
struct EnvelopeView: View {
    let summary: NodeSummary
    var triggerTicks: [Int] = []

    var body: some View {
        Canvas { context, size in
            // A control with a detail trace shows its first seconds, where single bangs are visible.
            if summary.isControl, !summary.detail.isEmpty {
                ControlTrace.draw([(summary.detail, .style(.tint), 1.5)], ticks: triggerTicks, in: context, size: size)
                return
            }
            let count = summary.maximums.count
            guard count > 0 else { return }
            // Audio is drawn against full scale; a control against the largest value it reached.
            let range = summary.isControl ? max(Double(summary.peak), 1) : 1
            func y(_ value: Float) -> CGFloat { (1 - CGFloat(Double(value) / range)) / 2 * size.height }
            let step = size.width / CGFloat(count)
            PlotLine.draw(context, from: CGPoint(x: 0, y: size.height / 2), to: CGPoint(x: size.width, y: size.height / 2))

            if summary.isControl {
                var band = Path()
                for (index, slice) in ControlBand.slices(of: summary).enumerated() {
                    let top = y(slice.high)
                    let bottom = y(slice.low)
                    // At least 1.5 pt tall, centred, so a slow signal (narrow band) still reads as a line.
                    let height = max(bottom - top, 1.5)
                    band.addRect(CGRect(x: CGFloat(index) * step, y: (top + bottom - height) / 2,
                                        width: max(step - 0.5, 0.5), height: height))
                }
                context.fill(band, with: .style(.tint.opacity(0.85)))
                return
            }
            var outer = Path()
            var inner = Path()
            for index in 0..<count {
                let x = CGFloat(index) * step
                let top = y(summary.maximums[index])
                let bottom = y(summary.minimums[index])
                outer.addRect(CGRect(x: x, y: top, width: max(step - 0.5, 0.5), height: max(bottom - top, 1)))
                let level = summary.rms[index]
                inner.addRect(CGRect(x: x, y: y(level), width: max(step - 0.5, 0.5), height: max(y(-level) - y(level), 1)))
            }
            context.fill(outer, with: .style(.tint.opacity(0.35)))
            context.fill(inner, with: .style(.tint.opacity(0.9)))
        }
    }
}

private enum PlotLine {
    static func draw(_ context: GraphicsContext, from: CGPoint, to: CGPoint) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
    }
}

extension Spectrogram {
    /// One pixel per cell, lowest band at the bottom, in an inferno-style ramp (dark → purple → orange → pale yellow).
    func image() -> CGImage? {
        guard columns > 0, rows > 0, values.count == columns * rows else { return nil }
        var pixels = [UInt8](repeating: 255, count: columns * rows * 4)
        for row in 0..<rows {
            for column in 0..<columns {
                let color = Self.color(at: Double(values[row * columns + column]) / 255)
                let offset = ((rows - 1 - row) * columns + column) * 4
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    static func color(at level: Double) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (0.00, 0.00, 0.02)), (0.25, (0.25, 0.05, 0.45)), (0.50, (0.75, 0.20, 0.30)),
            (0.75, (0.97, 0.55, 0.10)), (1.00, (1.00, 1.00, 0.80)),
        ]
        let level = min(max(level, 0), 1)
        var upper = 1
        while upper < stops.count - 1 && stops[upper].0 < level { upper += 1 }
        let (lowLevel, low) = stops[upper - 1]
        let (highLevel, high) = stops[upper]
        let t = (level - lowLevel) / (highLevel - lowLevel)
        func channel(_ a: Double, _ b: Double) -> UInt8 { UInt8((255 * (a + (b - a) * t)).rounded()) }
        return (channel(low.0, high.0), channel(low.1, high.1), channel(low.2, high.2))
    }
}

#Preview("Control summaries") {
    // A long Clock bake (a bang in every slice) and a slow LFO (one cycle across the bake).
    let slices = 160
    let clock = NodeSummary(
        sampleRate: 48_000, frames: 48_000 * 120, channels: 1, isControl: true,
        minimums: [Float](repeating: 0, count: slices), maximums: [Float](repeating: 1, count: slices),
        rms: [Float](repeating: 0.32, count: slices), spectrogram: nil
    )
    let curve = (0...slices).map { Float(sin(Double($0) / Double(slices) * 2 * .pi)) }
    let lfo = NodeSummary(
        sampleRate: 48_000, frames: 48_000 * 120, channels: 1, isControl: true,
        minimums: (0..<slices).map { min(curve[$0], curve[$0 + 1]) },
        maximums: (0..<slices).map { max(curve[$0], curve[$0 + 1]) },
        rms: [Float](repeating: 0.7, count: slices), spectrogram: nil
    )
    VStack(spacing: 16) {
        RenderedOutputView(summary: clock, isStale: false)
        RenderedOutputView(summary: lfo, isStale: false)
    }
    .tint(SignalType.control.color)
    .frame(width: 240)
    .padding()
}
