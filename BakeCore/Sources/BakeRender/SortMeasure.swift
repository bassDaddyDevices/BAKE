import BakeDSP
import BakeGraph
import Foundation

/// A Spectral Sorter's measure of a clip (mixed to mono), or nil when it has none.
public enum SortMeasure {
    public static func measure(_ url: URL, parameters: [ParameterID: ParameterValue], sampleRate: Double) throws -> Double? {
        let channels = try Scatter.read(url)
        guard let first = channels.first, !first.isEmpty else { return nil }
        let scale = 1 / Float(channels.count)
        let mono = (0..<first.count).map { i in channels.reduce(0) { $0 + $1[i] } * scale }
        let measure: bake.dsp.SortMeasure = switch SorterRoute.measureName(parameters) {
        case "loudness": .loudness
        case "pitch": .pitch
        case "decay": .decay
        default: .centroid
        }
        let value = bake.dsp.sortMeasure(measure, mono, mono.count, sampleRate)
        return value.isFinite ? value : nil
    }
}
