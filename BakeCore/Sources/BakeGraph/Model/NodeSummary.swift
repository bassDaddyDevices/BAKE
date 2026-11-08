/// A frequency-over-time picture of a finished signal: `rows` log-spaced bands from 30 Hz to
/// 20 kHz (row 0 the lowest) by `columns` slices of the signal. 0 is -90 dBFS or quieter, 255 is 0 dBFS.
public struct Spectrogram: Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    /// Row by row.
    public let values: [UInt8]

    public init(columns: Int, rows: Int, values: [UInt8]) {
        precondition(values.count == columns * rows, "A spectrogram needs columns × rows values")
        self.columns = columns
        self.rows = rows
        self.values = values
    }
}

/// What one node produced in the last bake, small enough to keep for every card: its waveform
/// envelope and, for audio, its spectrogram. Built from the render's own buffers, so seeing it costs nothing extra.
public struct NodeSummary: Hashable, Sendable {
    public let sampleRate: Double
    public let frames: Int
    public let channels: Int
    /// A control signal (LFO, Envelope, Math…), not audio.
    public let isControl: Bool
    /// Per slice of the signal: the lowest and highest sample of any channel, and their RMS.
    public let minimums: [Float]
    public let maximums: [Float]
    public let rms: [Float]
    /// Audio only.
    public let spectrogram: Spectrogram?
    /// Control only: the first `detailSeconds` at `detailRate` points a second (see `detailTrace`),
    /// fine enough to show single bangs, which the whole-bake slices above can't.
    public let detail: [Float]

    public static let detailSeconds = 4.0
    public static let detailRate = 250.0

    public init(
        sampleRate: Double, frames: Int, channels: Int, isControl: Bool,
        minimums: [Float], maximums: [Float], rms: [Float], spectrogram: Spectrogram?, detail: [Float] = []
    ) {
        self.detail = detail
        self.sampleRate = sampleRate
        self.frames = frames
        self.channels = channels
        self.isControl = isControl
        self.minimums = minimums
        self.maximums = maximums
        self.rms = rms
        self.spectrogram = spectrogram
    }

    public var seconds: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    /// The first `detailSeconds` of a signal as `detailRate` points a second. Point k covers the frames
    /// from k/rate to (k+1)/rate seconds and keeps the sample with the largest magnitude, sign
    /// included, so a one-sample bang still shows.
    public static func detailTrace(of samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> [Float] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        let frames = min(samples.count, Int(detailSeconds * sampleRate))
        let framesPerPoint = sampleRate / detailRate
        let count = Int((Double(frames) / framesPerPoint).rounded(.up))
        return (0..<count).map { point in
            let start = Int((Double(point) * framesPerPoint).rounded(.down))
            let end = min(Int((Double(point + 1) * framesPerPoint).rounded(.down)), frames)
            var strongest: Float = 0
            for frame in start..<max(end, start + 1) where frame < frames {
                let value = samples[frame].isFinite ? samples[frame] : 0
                if abs(value) > abs(strongest) { strongest = value }
            }
            return strongest
        }
    }

    /// The largest absolute sample.
    public var peak: Float { max(maximums.max() ?? 0, -(minimums.min() ?? 0)) }
}
