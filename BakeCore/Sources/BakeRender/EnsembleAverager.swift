import BakeDSP
import BakeGraph
import Foundation

/// Ensemble Averager's combine: the captures lined up, each bin of their spectra averaged, and the result
/// resynthesised with the phase of the most typical capture, refined by Griffin-Lim. Stereo when every
/// capture is stereo, otherwise mono; as long as the median aligned capture.
public enum EnsembleAverager {
    /// Griffin-Lim rounds at Phase Accuracy 100 %.
    static let maximumIterations = 32

    /// `progress` gets 0…1 as the captures are analysed and the average is resynthesised.
    public static func render(
        _ clips: [URL], parameters: [ParameterID: ParameterValue], sampleRate: Double, to output: URL,
        progress: ((Double) -> Void)? = nil
    ) throws {
        let audio = try clips.map(Scatter.read).filter { ($0.first?.count ?? 0) > 0 }
        guard !audio.isEmpty else {
            try Scatter.write([[0]], sampleRate: sampleRate, to: output)
            return
        }
        let stereo = audio.allSatisfy { $0.count >= 2 }
        let channels: [[[Float]]] = audio.map { clip in
            if stereo { return Array(clip.prefix(2)) }
            let scale = 1 / Float(clip.count)
            return [(0..<clip[0].count).map { i in clip.reduce(0) { $0 + $1[i] } * scale }]
        }
        let alignment = align(channels, choice("align", in: parameters) ?? "onset", sampleRate: sampleRate)
        let offsets = alignment.offsets.map { $0 - alignment.trim }
        let lengths = zip(channels, offsets).map { max(1, $0[0].count + $1) }.sorted()
        let frames = lengths[lengths.count / 2]

        let size = Int(choice("fftSize", in: parameters) ?? "2048") ?? 2048
        var layout = bake.dsp.StftLayout()
        layout.fftSize = Int32(size)
        layout.hop = Int32(size / 4)
        let frameCount = bake.dsp.stftFrameCount(layout, frames)
        let bins = bake.dsp.stftBinCount(layout)
        let values = frameCount * bins
        let spectrumFloats = bake.dsp.stftSpectrumFloats(layout, frameCount)
        let rowFloats = bake.dsp.stftRowFloats(layout, frameCount)
        try NodeMemory.require(bytes: (audio.count * values + values + spectrumFloats + rowFloats + 2 * frames) * MemoryLayout<Float>.size)

        let mode: bake.dsp.AverageMode = switch choice("mode", in: parameters) {
        case "median": .median
        case "geometric": .geometric
        default: .mean
        }
        let trim = (parameters["trim"]?.numberValue ?? 0) / 100
        let iterations = Int(((parameters["phaseAccuracy"]?.numberValue ?? 50) / 100 * Double(maximumIterations)).rounded())

        var scratch = [Double](repeating: 0, count: max(bake.dsp.ensembleScratchDoubles(layout), audio.count))
        var spectrum = [Float](repeating: 0, count: spectrumFloats)
        var rows = [Float](repeating: 0, count: rowFloats)
        var magnitudes = [Float](repeating: 0, count: audio.count * values)
        var average = [Float](repeating: 0, count: values)
        var result: [[Float]] = []

        for channel in 0..<channels[0].count {
            // A capture moved by its offset and cut or padded to the output's length.
            func signal(_ clip: Int) -> [Float] {
                var out = [Float](repeating: 0, count: frames)
                let source = channels[clip][channel]
                // A negative offset drops that many frames from the front (the trimmed lead-in).
                let offset = offsets[clip]
                for i in max(0, -offset)..<max(max(0, -offset), min(source.count, frames - offset)) { out[offset + i] = source[i] }
                return out
            }
            func analyse(_ clip: Int) {
                let input = signal(clip)
                bake.dsp.stftForward(layout, input, frames, 0, frameCount, &spectrum, &scratch)
            }
            let steps = Double(channels[0].count * (channels.count + 1))
            for clip in channels.indices {
                progress?(Double(channel * (channels.count + 1) + clip) / steps)
                analyse(clip)
                magnitudes.withUnsafeMutableBufferPointer { m in
                    bake.dsp.stftMagnitudes(spectrum, frameCount, bins, m.baseAddress! + clip * values)
                }
            }
            bake.dsp.ensembleAverage(magnitudes, audio.count, values, mode, trim, &scratch, &average)
            analyse(bake.dsp.ensembleTypical(magnitudes, audio.count, values, average))
            var out = [Float](repeating: 0, count: frames)
            bake.dsp.ensembleGriffinLim(layout, average, &spectrum, frameCount, frames, iterations, &rows, &out, &scratch)
            result.append(out)
            progress?(Double((channel + 1) * (channels.count + 1)) / steps)
        }
        try Scatter.write(result, sampleRate: sampleRate, to: output)
    }

    private static func choice(_ id: ParameterID, in parameters: [ParameterID: ParameterValue]) -> String? {
        if case .choice(let value)? = parameters[id] { value } else { nil }
    }

    /// How far each capture moves right, and how many frames of lead-in every one of them shares (dropped from
    /// the front, all but 5 ms). Start: no move, no trim. Onset: each capture's first sample within 20 dB of its
    /// peak lands where the latest one's is. Peak: its loudest sample does.
    static func align(_ channels: [[[Float]]], _ mode: String, sampleRate: Double) -> (offsets: [Int], trim: Int) {
        guard mode != "start" else { return (channels.map { _ in 0 }, 0) }
        func level(_ clip: [[Float]], _ i: Int) -> Float { clip.reduce(0) { max($0, abs($1[i])) } }
        let marks = channels.map { clip -> (mark: Int, audible: Int) in
            var peak = 0
            var loudest: Float = -1
            for i in clip[0].indices where level(clip, i) > loudest {
                loudest = level(clip, i)
                peak = i
            }
            let onset = clip[0].indices.first { level(clip, $0) >= loudest * 0.1 } ?? 0
            let audible = clip[0].indices.first { level(clip, $0) >= loudest * 0.001 } ?? 0  // −60 dB
            return (mode == "peak" ? peak : onset, audible)
        }
        let latest = marks.map(\.mark).max() ?? 0
        let offsets = marks.map { latest - $0.mark }
        let shared = zip(offsets, marks).map { $0 + $1.audible }.min() ?? 0
        return (offsets, max(0, shared - Int((0.005 * sampleRate).rounded())))
    }
}
