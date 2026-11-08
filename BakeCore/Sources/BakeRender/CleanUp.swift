import AVFAudio
import BakeGraph
import Foundation

/// A Bake's Clean Up (Auto-Prune & Normalize), applied as its file is written. The render goes to a
/// 32-bit float scratch file first; then, a block at a time: Remove DC (each channel's mean) → trim
/// everything before the first and after the last frame louder than the Noise Floor → a raised-cosine
/// Micro-Fade in and out → scale the peak to Target Peak. A file never louder than the floor is kept
/// whole and unscaled (with its DC removed), rather than trimmed to nothing.
struct CleanUp {
    let floor: Float
    let fadeFrames: Int
    let removesDC: Bool
    let targetPeak: Float?

    /// Nil when the node's Clean Up is off.
    init?(parameters: [ParameterID: ParameterValue], sampleRate: Double) {
        guard parameters["cleanUp"] == .choice("on") else { return nil }
        floor = Float(pow(10, (parameters["noiseFloor"]?.numberValue ?? -60) / 20))
        fadeFrames = Int(((parameters["fade"]?.numberValue ?? 2) * 0.001 * sampleRate).rounded())
        removesDC = parameters["dcRemoval"] == .choice("on")
        targetPeak = parameters["normalize"] == .choice("off") ? nil : Float(pow(10, (parameters["targetPeak"]?.numberValue ?? -0.1) / 20))
    }

    /// The raised cosine `frame` frames into a fade of `length`: 0 at the edge, 1 from `length` on.
    static func fadeGain(_ frame: Int, length: Int) -> Float {
        guard length > 0, frame < length else { return 1 }
        return Float(0.5 * (1 - cos(Double.pi * Double(frame) / Double(length))))
    }

    /// Reads `scratch` and writes the cleaned file into `output`, already open at the Bake's format.
    func apply(scratch: URL, to output: AVAudioFile) throws {
        let source = try AVAudioFile(forReading: scratch)
        let channels = Int(source.processingFormat.channelCount)
        let total = Int(source.length)

        // Pass 1: each channel's mean, for Remove DC.
        var means = [Float](repeating: 0, count: channels)
        if removesDC, total > 0 {
            var sums = [Double](repeating: 0, count: channels)
            try forEachBlock(of: source) { data, start, count in
                for channel in 0..<channels {
                    for i in 0..<count { sums[channel] += Double(data[channel][i]) }
                }
            }
            means = sums.map { Float($0 / Double(total)) }
        }

        // Pass 2: the first and last frame above the floor, and the peak between them.
        var first: Int?
        var last = -1
        var peak: Float = 0
        try forEachBlock(of: source) { data, start, count in
            for i in 0..<count {
                var loudest: Float = 0
                for channel in 0..<channels { loudest = max(loudest, abs(data[channel][i] - means[channel])) }
                if loudest > floor {
                    if first == nil { first = start + i }
                    last = start + i
                }
                peak = max(peak, loudest)
            }
        }
        let range: Range<Int>
        let gain: Float
        if let first {
            range = first..<(last + 1)
            // The peak is always inside the kept range: everything outside it is below the floor.
            gain = targetPeak.map { peak > 0 ? $0 / peak : 1 } ?? 1
        } else {
            range = 0..<total
            gain = 1
        }
        let fade = first == nil ? 0 : min(fadeFrames, range.count / 2)

        // Pass 3: the kept frames, without DC, faded and scaled.
        try forEachBlock(of: source) { data, start, count in
            let lower = max(start, range.lowerBound), upper = min(start + count, range.upperBound)
            guard lower < upper, let block = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(upper - lower)),
                  let out = block.floatChannelData else { return }
            block.frameLength = AVAudioFrameCount(upper - lower)
            for frame in lower..<upper {
                let position = frame - range.lowerBound
                let shape = Self.fadeGain(position, length: fade) * Self.fadeGain(range.count - 1 - position, length: fade)
                for channel in 0..<channels {
                    out[channel][frame - lower] = (data[channel][frame - start] - means[channel]) * gain * shape
                }
            }
            try output.write(from: block)
        }
    }

    /// Calls `body` with each block of the file: its channels, its first frame and its length.
    private func forEachBlock(of file: AVAudioFile, _ body: (UnsafePointer<UnsafeMutablePointer<Float>>, Int, Int) throws -> Void) throws {
        let blockSize = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(blockSize)) else { return }
        file.framePosition = 0
        var start = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(blockSize))
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            try body(UnsafePointer(data), start, count)
            start += count
        }
    }
}
