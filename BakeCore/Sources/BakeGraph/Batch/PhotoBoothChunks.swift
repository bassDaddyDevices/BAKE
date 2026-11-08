import Foundation

/// Where a Photo Booth cuts its input: a chunk starts at each trigger (a rising edge above 0.5, or a bang
/// of its own grid when Trigger is unwired) and runs to the next one (Until Next) or for a set length
/// (Fixed); the last ends at the input's end. Chunks shorter than Min Length are skipped.
public enum PhotoBoothChunks {
    /// The most chunks one Photo Booth makes.
    public static let maximumChunks = 10_000

    /// Frames in one `choice` ("1/1" … "1/32" at `bpm`, a quarter note being one beat; "ms": `milliseconds`).
    public static func frames(of choice: String, milliseconds: Double, bpm: Double, sampleRate: Double) -> Double {
        let seconds: Double
        if choice == "ms" {
            seconds = milliseconds / 1_000
        } else {
            let denominator = Double(choice.split(separator: "/").last.flatMap { Int($0) } ?? 4)
            seconds = 60 / max(bpm, 1) * 4 / denominator
        }
        return max(1, seconds * sampleRate)
    }

    /// Frames between the grid's bangs (Every at BPM, or ms).
    public static func period(_ parameters: [ParameterID: ParameterValue], sampleRate: Double) -> Double {
        frames(of: choice("every", parameters) ?? "1/4", milliseconds: parameters["everyMs"]?.numberValue ?? 250,
               bpm: parameters["bpm"]?.numberValue ?? 120, sampleRate: sampleRate)
    }

    /// Whether the grid bangs on `frame`: the nearest multiple of the period, rounded, is this frame.
    public static func isGridBang(_ frame: Int, period: Double) -> Bool {
        let k = (Double(frame) / period).rounded()
        return Int((k * period).rounded()) == frame
    }

    /// The grid's bangs in `frames`.
    public static func gridStarts(frames: Int, parameters: [ParameterID: ParameterValue], sampleRate: Double) -> [Int] {
        let period = period(parameters, sampleRate: sampleRate)
        var starts: [Int] = []
        var k = 0.0
        while starts.count <= maximumChunks {
            let frame = Int((k * period).rounded())
            guard frame < frames else { break }
            starts.append(frame)
            k += 1
        }
        return starts
    }

    /// The frames where `trigger` rises above 0.5 (the first frame counts if it starts above).
    public static func rises(_ trigger: [Float]) -> [Int] {
        trigger.indices.filter { trigger[$0] > 0.5 && ($0 == 0 || trigger[$0 - 1] <= 0.5) }
    }

    /// The chunks of an input `frames` long that start at `starts`.
    public static func chunks(starts: [Int], frames: Int, parameters: [ParameterID: ParameterValue], sampleRate: Double) -> [Range<Int>] {
        let starts = starts.filter { $0 >= 0 && $0 < frames }
        let fixed = parameters["length"] == .choice("fixed")
        let length = fixed
            ? Int(self.frames(of: choice("fixedLength", parameters) ?? "1/16", milliseconds: parameters["fixedMs"]?.numberValue ?? 100,
                              bpm: parameters["bpm"]?.numberValue ?? 120, sampleRate: sampleRate).rounded())
            : 0
        let minimum = Int(((parameters["minLength"]?.numberValue ?? 10) * 0.001 * sampleRate).rounded())
        var chunks: [Range<Int>] = []
        for (index, start) in starts.enumerated() {
            let end = fixed ? min(frames, start + length) : (index + 1 < starts.count ? starts[index + 1] : frames)
            guard end - start >= max(1, minimum) else { continue }
            chunks.append(start..<end)
            if chunks.count == maximumChunks { break }
        }
        return chunks
    }

    /// How many chunks the grid makes of an input `frames` long (what the card shows before a bake).
    public static func gridCount(frames: Int, parameters: [ParameterID: ParameterValue], sampleRate: Double) -> Int {
        chunks(starts: gridStarts(frames: frames, parameters: parameters, sampleRate: sampleRate),
               frames: frames, parameters: parameters, sampleRate: sampleRate).count
    }

    private static func choice(_ id: ParameterID, _ parameters: [ParameterID: ParameterValue]) -> String? {
        if case .choice(let value)? = parameters[id] { value } else { nil }
    }
}
