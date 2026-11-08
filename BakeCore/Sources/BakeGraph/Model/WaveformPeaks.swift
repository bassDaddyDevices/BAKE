/// A waveform summary for drawing: the loudest absolute sample in each slice of a file, 0…1.
public struct WaveformPeaks: Hashable, Sendable {
    public let peaks: [Float]

    public init(peaks: [Float]) {
        self.peaks = peaks.map { $0.isFinite ? min(abs($0), 1) : 0 }
    }
}
