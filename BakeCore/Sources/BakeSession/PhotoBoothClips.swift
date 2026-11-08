import AVFAudio
import BakeGraph
import BakeRender
import Foundation

/// A captured Photo Booth cut into clips: a chunk at each rising edge of its captured trigger
/// (`PhotoBoothChunks`), each written as a 32-bit float clip with raised-cosine fades, named
/// `<stem>-001.wav` and so on.
enum PhotoBoothClips {
    static func clips(
        input: URL, trigger: URL, parameters: [ParameterID: ParameterValue], stem: String, into folder: URL
    ) throws -> [BatchFile] {
        guard let source = try? AVAudioFile(forReading: input) else { throw RenderError.unreadableAsset(input) }
        let sampleRate = source.processingFormat.sampleRate
        let starts = PhotoBoothChunks.rises(try firstChannel(of: trigger))
        let chunks = PhotoBoothChunks.chunks(starts: starts, frames: Int(source.length), parameters: parameters, sampleRate: sampleRate)
        let width = max(3, String(chunks.count).count)
        let fadeFrames = Int(((parameters["fade"]?.numberValue ?? 2) * 0.001 * sampleRate).rounded())
        return try chunks.enumerated().map { index, chunk in
            let number = String(index + 1)
            let clip = folder.appending(path: "\(stem)-\(String(repeating: "0", count: max(0, width - number.count)))\(number).wav")
            try SliceClips.write(chunk, of: source, url: input, to: clip, fadeFrames: fadeFrames)
            return BatchFile(path: clip.path(percentEncoded: false))
        }
    }

    /// The first channel of a whole file, read a block at a time.
    static func firstChannel(of url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
            throw RenderError.unreadableAsset(url)
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return samples
    }
}
