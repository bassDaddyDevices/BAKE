import Foundation

/// Where each clip of a join starts. With a Gap above 0 there is that much silence between clips and no
/// crossfade; with Gap 0, neighbours overlap by the Crossfade, at most half of either clip (`holds[k]` is how
/// much of clip `k`'s end overlaps clip `k + 1`). The same rules as the batch join (`Concatenation`).
public struct JoinPlan: Hashable, Sendable {
    public let starts: [Int]
    public let holds: [Int]
    public let total: Int

    public init(lengths: [Int], gapFrames: Int, crossfadeFrames: Int) {
        let fade = gapFrames > 0 ? 0 : max(0, crossfadeFrames)
        var starts: [Int] = []
        var holds: [Int] = []
        var position = 0
        for (k, length) in lengths.enumerated() {
            starts.append(position)
            let hold = k + 1 < lengths.count ? min(fade, length / 2, lengths[k + 1] / 2) : 0
            holds.append(hold)
            position += length - hold + (k + 1 < lengths.count ? max(0, gapFrames) : 0)
        }
        self.starts = starts
        self.holds = holds
        total = lengths.isEmpty ? 0 : (starts.last ?? 0) + (lengths.last ?? 0)
    }

    /// Gap and Crossfade in ms, from a node's parameters.
    public init(lengths: [Int], parameters: [ParameterID: ParameterValue], gap: ParameterID = "gap",
                crossfade: ParameterID = "crossfade", sampleRate: Double) {
        let gapFrames = Int(((parameters[gap]?.numberValue ?? 0) * 0.001 * sampleRate).rounded())
        let fadeFrames = Int(((parameters[crossfade]?.numberValue ?? 10) * 0.001 * sampleRate).rounded())
        self.init(lengths: lengths, gapFrames: gapFrames, crossfadeFrames: fadeFrames)
    }
}
