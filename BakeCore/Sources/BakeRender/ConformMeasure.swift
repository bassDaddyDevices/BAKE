import BakeDSP
import BakeGraph
import Foundation

/// Batch Conform's detection on a captured file (mixed to mono): its tempo folded toward `target`, and its key.
public enum ConformMeasure {
    public static func measure(_ url: URL, target: Double, sampleRate: Double) throws -> (bpm: Double?, key: ConformName.Key?) {
        let channels = try Scatter.read(url)
        guard let first = channels.first, !first.isEmpty else { return (nil, nil) }
        let scale = 1 / Float(channels.count)
        let mono = (0..<first.count).map { i in channels.reduce(0) { $0 + $1[i] } * scale }
        let bpm = bake.dsp.conformTempo(mono, mono.count, sampleRate, target)
        let key = Int(bake.dsp.conformKey(mono, mono.count, sampleRate))
        return (bpm.isFinite ? bpm : nil, key >= 0 ? ConformName.Key(root: key % 12, minor: key >= 12) : nil)
    }
}
