import BakeGraph
import SwiftUI

/// A compact, centred bar waveform.
struct WaveformView: View {
    let peaks: WaveformPeaks

    var body: some View {
        Canvas { context, size in
            let bars = Self.bars(for: peaks, count: max(Int(size.width / 2), 1))
            guard !bars.isEmpty else { return }
            let step = size.width / CGFloat(bars.count)
            var path = Path()
            for (index, peak) in bars.enumerated() {
                let height = max(CGFloat(peak) * size.height, 1)
                path.addRect(CGRect(
                    x: CGFloat(index) * step, y: (size.height - height) / 2,
                    width: max(step - 0.5, 0.5), height: height
                ))
            }
            context.fill(path, with: .style(.tint.opacity(0.8)))
        }
        .frame(height: 36)
        .accessibilityLabel("Waveform")
    }

    /// The loudest peak in each of `count` equal slices; never more bars than peaks.
    nonisolated static func bars(for peaks: WaveformPeaks, count: Int) -> [Float] {
        let source = peaks.peaks
        guard !source.isEmpty, count > 0 else { return [] }
        guard source.count > count else { return source }
        return (0..<count).map { bar in
            let start = bar * source.count / count
            let end = max((bar + 1) * source.count / count, start + 1)
            return source[start..<end].max() ?? 0
        }
    }
}
