import AVFAudio
import BakeGraph
import BakeRender
import Foundation

/// Concatenate's join: the passes' captures (all at the project rate) end to end in one 32-bit float
/// WAV, a block at a time, so only a crossfade's overlap is ever held.
///
/// With Gap above 0 there is that much silence between clips and no crossfade. With Gap 0, neighbours
/// overlap by Crossfade (at most half of either clip) with an equal-power curve: in an overlap of `L`
/// frames, frame `i` is `a·cos θ + b·sin θ` with `θ = π/2 · (i + ½) / L`. The result has the most channels
/// any clip has; a mono clip fills every channel, and a clip with fewer leaves the rest silent.
public enum Concatenation {
    public static func join(_ clips: [URL], parameters: [ParameterID: ParameterValue], to output: URL) throws {
        let files = try clips.map { url in
            do { return try AVAudioFile(forReading: url) } catch { throw RenderError.unreadableAsset(url) }
        }
        guard let rate = files.first?.processingFormat.sampleRate else { throw RenderError.unreadableAsset(output) }
        let channels = files.map { Int($0.processingFormat.channelCount) }.max() ?? 1
        let lengths = files.map { Int($0.length) }
        let order = self.order(lengths, parameters: parameters)
        let gap = Int(((parameters["gap"]?.numberValue ?? 0) * 0.001 * rate).rounded())
        let fade = gap > 0 ? 0 : Int(((parameters["crossfade"]?.numberValue ?? 10) * 0.001 * rate).rounded())
        // How much of each clip's end overlaps the next clip's start.
        let holds = order.indices.map { k -> Int in
            guard k + 1 < order.count else { return 0 }
            return min(fade, lengths[order[k]] / 2, lengths[order[k + 1]] / 2)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let writer = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var tail = [[Float]](repeating: [], count: channels)
        for (k, index) in order.enumerated() {
            if k > 0, gap > 0 {
                try write([[Float]](repeating: [Float](repeating: 0, count: gap), count: channels), to: writer)
            }
            let overlap = k > 0 ? holds[k - 1] : 0
            let hold = holds[k]
            let length = lengths[index]
            var position = 0
            try read(files[index], url: clips[index], into: channels) { block in
                let count = block[0].count
                var out = [[Float]](repeating: [], count: channels)
                var held = [[Float]](repeating: [], count: channels)
                for channel in 0..<channels {
                    out[channel].reserveCapacity(count)
                    for i in 0..<count {
                        let frame = position + i
                        let sample = block[channel][i]
                        if frame < overlap {
                            let theta = Double.pi / 2 * (Double(frame) + 0.5) / Double(overlap)
                            out[channel].append(Float(Double(tail[channel][frame]) * cos(theta) + Double(sample) * sin(theta)))
                        } else if frame >= length - hold {
                            held[channel].append(sample)
                        } else {
                            out[channel].append(sample)
                        }
                    }
                }
                position += count
                try write(out, to: writer)
                for channel in 0..<channels where !held[channel].isEmpty {
                    if position - count < length - hold { tail[channel] = [] }
                    tail[channel] += held[channel]
                }
            }
        }
    }

    /// The order clips are joined in: as they came, shortest or longest first (ties as they came), or
    /// a shuffle from the Seed that's the same on every Mac.
    static func order(_ lengths: [Int], parameters: [ParameterID: ParameterValue]) -> [Int] {
        let indices = Array(lengths.indices)
        switch parameters["order"] {
        case .choice("shortest")?: return indices.sorted { (lengths[$0], $0) < (lengths[$1], $1) }
        case .choice("longest")?: return indices.sorted { (-lengths[$0], $0) < (-lengths[$1], $1) }
        case .choice("random")?:
            let seed = UInt64(max(0, parameters["seed"]?.numberValue ?? 1))
            return indices.sorted { (hash(seed, $0), $0) < (hash(seed, $1), $1) }
        default: return indices
        }
    }

    /// splitmix64 of (seed, index).
    private static func hash(_ seed: UInt64, _ index: Int) -> UInt64 {
        var x = (seed << 32) ^ UInt64(index)
        x &+= 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    /// Calls `body` with each block of the file, mapped onto `channels`.
    private static func read(_ file: AVAudioFile, url: URL, into channels: Int, _ body: ([[Float]]) throws -> Void) throws {
        let block = 65_536
        let fileChannels = Int(file.processingFormat.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)) else {
            throw RenderError.unreadableAsset(url)
        }
        file.framePosition = 0
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(block)) } catch { throw RenderError.unreadableAsset(url) }
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            let mapped = (0..<channels).map { channel -> [Float] in
                if fileChannels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: count)) }
                if channel < fileChannels { return Array(UnsafeBufferPointer(start: data[channel], count: count)) }
                return [Float](repeating: 0, count: count)
            }
            try body(mapped)
        }
    }

    private static func write(_ samples: [[Float]], to file: AVAudioFile) throws {
        let count = samples.first?.count ?? 0
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        for (channel, values) in samples.enumerated() {
            values.withUnsafeBufferPointer { data[channel].update(from: $0.baseAddress!, count: count) }
        }
        try file.write(from: buffer)
    }
}
