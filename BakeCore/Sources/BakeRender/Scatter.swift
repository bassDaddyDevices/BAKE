import AVFAudio
import BakeDSP
import BakeGraph
import Foundation

/// Corpus Scatter's combine: every capture placed along one stereo timeline, Total Duration long, where
/// `ScatterSchedule` says.
public enum Scatter {
    /// Reads the captures and writes the scattered file: stereo, 32-bit float, Total Duration long.
    public static func render(_ clips: [URL], parameters: [ParameterID: ParameterValue], sampleRate: Double, to output: URL) throws {
        let audio = try clips.map(read)
        let bytes = audio.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } * MemoryLayout<Float>.size
        let frames = max(1, Int(((parameters["duration"]?.numberValue ?? 10) * sampleRate).rounded()))
        try NodeMemory.require(bytes: bytes + frames * 2 * MemoryLayout<Float>.size)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        let gain = pow(10, (parameters["level"]?.numberValue ?? -6) / 20)
        let fade = Int(((parameters["grainFade"]?.numberValue ?? 5) * 0.001 * sampleRate).rounded())
        for grain in ScatterSchedule.grains(clips: audio.count, parameters: parameters, sampleRate: sampleRate) {
            let clip = audio[grain.clip]
            guard let first = clip.first, !first.isEmpty else { continue }
            clip[0].withUnsafeBufferPointer { a in
                clip[min(1, clip.count - 1)].withUnsafeBufferPointer { b in
                    let pointers: [UnsafePointer<Float>?] = clip.count > 1 ? [a.baseAddress, b.baseAddress] : [a.baseAddress]
                    pointers.withUnsafeBufferPointer { channels in
                        left.withUnsafeMutableBufferPointer { l in
                            right.withUnsafeMutableBufferPointer { r in
                                _ = bake.dsp.scatterPlace(
                                    channels.baseAddress, min(clip.count, 2), first.count, l.baseAddress, r.baseAddress, frames,
                                    grain.start, pow(2, grain.semitones / 12), grain.pan, gain, fade
                                )
                            }
                        }
                    }
                }
            }
        }
        // A grain still sounding at the end is cut: a short fade so the file doesn't end on a click.
        let tail = min(frames, Int(0.005 * sampleRate))
        for i in 0..<tail {
            let shape = Float(0.5 * (1 - cos(Double.pi * Double(i) / Double(tail))))
            left[frames - 1 - i] *= shape
            right[frames - 1 - i] *= shape
        }
        try write([left, right], sampleRate: sampleRate, to: output)
    }

    /// The whole file, one array per channel. One `read(into:)` may return fewer frames than asked for, so it loops.
    static func read(_ url: URL) throws -> [[Float]] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
            throw RenderError.unreadableAsset(url)
        }
        var channels = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        for index in channels.indices { channels[index].reserveCapacity(Int(file.length)) }
        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { throw RenderError.unreadableAsset(url) }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for index in channels.indices {
                channels[index].append(contentsOf: UnsafeBufferPointer(start: data[index], count: Int(buffer.frameLength)))
            }
        }
        return channels
    }

    /// 32-bit float WAV.
    static func write(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        let frames = channels.first?.count ?? 0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let data = buffer.floatChannelData else { throw RenderError.writeFailed(url) }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { data[index].update(from: $0.baseAddress!, count: frames) }
        }
        try file.write(from: buffer)
    }
}
