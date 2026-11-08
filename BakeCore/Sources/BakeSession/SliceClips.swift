import AVFAudio
import BakeGraph
import BakeRender
import CryptoKit
import Foundation

/// A Large Audio Processor's slices as files a batch can play. Each file and set of slicing settings has
/// its own folder in `cache`, named by a hash of the file's path, size and modification date and the
/// settings: the analysis is kept there (`slices.json`), and the clips (`<recording> 001.wav` …, with a
/// raised-cosine Micro-Fade in and out) are written once, when a bake first needs them.
public enum SliceClips {
    /// Settings that change where the cuts fall or how the clips sound; Gain and Interpolation apply when a clip plays.
    static let slicingParameters: [ParameterID] = [
        "sliceMode", "threshold", "sensitivity", "bpm", "bars", "every", "minLength", "maxLength", "fade", "backTrack", "jitter", "seed",
    ]

    private struct Manifest: Codable {
        var slices: [[Int]]
    }

    /// Where the file is cut (frames at its own rate), from the cache or analysed now.
    public static func slices(for url: URL, parameters: [ParameterID: ParameterValue], in cache: URL) throws -> [Range<Int>] {
        let folder = try folder(for: url, parameters: parameters, in: cache)
        let manifest = folder.appending(path: "slices.json")
        if let data = try? Data(contentsOf: manifest), let saved = try? JSONDecoder().decode(Manifest.self, from: data) {
            return saved.slices.compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]..<$0[1] : nil }
        }
        let slices = try SliceAnalysis.slices(of: url, parameters: parameters)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(Manifest(slices: slices.map { [$0.lowerBound, $0.upperBound] })).write(to: manifest, options: .atomic)
        return slices
    }

    /// The slices as clips, written now unless they're already in the cache.
    public static func clips(for url: URL, parameters: [ParameterID: ParameterValue], in cache: URL) throws -> [BatchFile] {
        let slices = try slices(for: url, parameters: parameters, in: cache)
        let folder = try folder(for: url, parameters: parameters, in: cache)
        let stem = url.deletingPathExtension().lastPathComponent
        let width = max(3, String(slices.count).count)
        let urls = slices.indices.map { index in
            folder.appending(path: "\(stem) \(String(repeating: "0", count: max(0, width - String(index + 1).count)))\(index + 1).wav")
        }
        let done = folder.appending(path: "clips.done")
        if !FileManager.default.fileExists(atPath: done.path(percentEncoded: false)) {
            guard let source = try? AVAudioFile(forReading: url) else { throw RenderError.unreadableAsset(url) }
            let fadeFrames = Int((parameters["fade"]?.numberValue ?? 2) * 0.001 * source.processingFormat.sampleRate)
            for (slice, clip) in zip(slices, urls) {
                try write(slice, of: source, url: url, to: clip, fadeFrames: fadeFrames)
            }
            try Data().write(to: done)
        }
        return urls.map { BatchFile(path: $0.path(percentEncoded: false)) }
    }

    /// The fade's gain `frame` frames in: 0 at the edge, rising as a raised cosine to 1 after `fadeFrames`.
    static func fadeGain(_ frame: Int, fadeFrames: Int) -> Float {
        guard fadeFrames > 0, frame < fadeFrames else { return 1 }
        return Float(0.5 * (1 - cos(Double.pi * Double(frame) / Double(fadeFrames))))
    }

    private static func folder(for url: URL, parameters: [ParameterID: ParameterValue], in cache: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var key = url.resolvingSymlinksInPath().path(percentEncoded: false)
        key += "|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        for id in slicingParameters {
            key += "|\(id)=\(parameters[id].map { "\($0)" } ?? "-")"
        }
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return cache.appending(path: digest, directoryHint: .isDirectory)
    }

    /// One slice, copied a block at a time into a 32-bit float WAV at the source's rate, faded at both ends.
    static func write(_ slice: Range<Int>, of source: AVAudioFile, url: URL, to clip: URL, fadeFrames: Int) throws {
        let format = source.processingFormat
        let channels = Int(format.channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let output = try AVAudioFile(forWriting: clip, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)) else { throw RenderError.unreadableAsset(url) }
        let fade = min(fadeFrames, slice.count / 2)
        source.framePosition = AVAudioFramePosition(slice.lowerBound)
        var written = 0
        while written < slice.count {
            let want = min(block, slice.count - written)
            try source.read(into: buffer, frameCount: AVAudioFrameCount(want))
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<got {
                let position = written + frame
                let gain = fadeGain(position, fadeFrames: fade) * fadeGain(slice.count - 1 - position, fadeFrames: fade)
                if gain == 1 { continue }
                for channel in 0..<channels { data[channel][frame] *= gain }
            }
            try output.write(from: buffer)
            written += got
        }
    }
}
