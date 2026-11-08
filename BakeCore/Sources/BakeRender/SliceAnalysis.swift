import AVFAudio
import BakeDSP
import BakeGraph
import Foundation

/// Where a Large Audio Processor cuts its file, in frames at the file's own rate. The file is read in
/// blocks of about a second and mixed to mono, so a 2-hour recording never sits in memory: Transient
/// keeps one energy value per 256 frames, the grid modes nothing at all. Every cut is then snapped to
/// the nearest zero crossing within 5 ms, reading just those few frames.
public enum SliceAnalysis {
    static let hop = 256
    /// Frames per block read; a whole number of hops, so the energy never straddles two blocks.
    static let block = hop * 188

    public static func slices(of url: URL, parameters: [ParameterID: ParameterValue]) throws(RenderError) -> [Range<Int>] {
        guard let file = try? AVAudioFile(forReading: url) else { throw .unreadableAsset(url) }
        let rate = file.processingFormat.sampleRate
        let total = Int(file.length)
        guard total > 0, rate > 0 else { return [] }
        let mode = parameters["sliceMode"] ?? .choice("transient")
        let threshold = parameters["threshold"]?.numberValue ?? -40

        var energy: [Double] = []
        var boundaries: [Int]
        switch mode {
        case .choice("musical"):
            let bars = Double(parameters["bars"].flatMap { if case .choice(let bars) = $0 { bars } else { nil } } ?? "1") ?? 1
            let seconds = bars * 4 * 60 / max(parameters["bpm"]?.numberValue ?? 120, 1)
            boundaries = grid(every: seconds * rate, total: total)
        case .choice("seconds"):
            boundaries = grid(every: (parameters["every"]?.numberValue ?? 2) * rate, total: total)
        default:
            energy = try streamEnergy(of: file, url: url)
            var settings = bake.dsp.SliceSettings()
            settings.thresholdDb = threshold
            settings.sensitivityDb = parameters["sensitivity"]?.numberValue ?? 6
            settings.hop = hop
            settings.sampleRate = rate
            settings.backTrack = parameters["backTrack"] != .choice("off")
            var onsets = [Int](repeating: 0, count: max(energy.count, 1))
            let count = energy.withUnsafeBufferPointer { energy in
                onsets.withUnsafeMutableBufferPointer { out in
                    bake.dsp.sliceOnsets(energy.baseAddress, energy.count, settings, out.baseAddress, out.count)
                }
            }
            boundaries = Array(onsets.prefix(count))
        }

        let minFrames = Int((parameters["minLength"]?.numberValue ?? 100) * 0.001 * rate)
        let maxFrames = max(Int((parameters["maxLength"]?.numberValue ?? 10) * rate), 1)
        let jitter = (parameters["jitter"]?.numberValue ?? 0) / 100
        let seed = UInt32(max(0, parameters["seed"]?.numberValue ?? 1))
        let capacity = boundaries.count + total / maxFrames + 2
        var starts = [Int](repeating: 0, count: capacity)
        var ends = [Int](repeating: 0, count: capacity)
        let count = boundaries.withUnsafeBufferPointer { boundaries in
            starts.withUnsafeMutableBufferPointer { starts in
                ends.withUnsafeMutableBufferPointer { ends in
                    bake.dsp.sliceRanges(
                        boundaries.baseAddress, boundaries.count, total, minFrames, maxFrames, jitter, seed,
                        starts.baseAddress, ends.baseAddress, capacity
                    )
                }
            }
        }
        var ranges = (0..<count).map { starts[$0]..<ends[$0] }

        // Transient: a slice that never gets above Threshold (a long silent tail cut at Max Length) is left out.
        if !energy.isEmpty {
            ranges = ranges.filter { range in
                let hops = (range.lowerBound / hop)..<min(energy.count, (range.upperBound + hop - 1) / hop)
                return hops.contains { 10 * log10(max(energy[$0], 1e-12)) >= threshold }
            }
        }
        return try snapped(ranges, in: file, url: url, rate: rate, total: total)
    }

    private static func grid(every frames: Double, total: Int) -> [Int] {
        let step = max(frames, 1)
        return stride(from: 0.0, to: Double(total), by: step).map { Int($0.rounded()) }
    }

    /// One energy value per hop of the whole file, read a block at a time.
    private static func streamEnergy(of file: AVAudioFile, url: URL) throws(RenderError) -> [Double] {
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)) else {
            throw .unreadableAsset(url)
        }
        var mono = [Float](repeating: 0, count: block)
        var energy: [Double] = []
        energy.reserveCapacity(Int(file.length) / hop + 1)
        var chunk = [Double](repeating: 0, count: block / hop)
        file.framePosition = 0
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(block)) } catch { throw .unreadableAsset(url) }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            mixDown(data, channels: channels, frames: frames, into: &mono)
            let values = (frames + hop - 1) / hop
            mono.withUnsafeBufferPointer { mono in
                chunk.withUnsafeMutableBufferPointer { out in
                    bake.dsp.sliceEnergy(mono.baseAddress, frames, hop, out.baseAddress)
                }
            }
            energy.append(contentsOf: chunk.prefix(values))
        }
        return energy
    }

    /// Snaps every start and end to the nearest zero crossing within 5 ms (ends and starts that meet
    /// stay meeting: the same frame snaps the same way). The file's own ends stay put.
    private static func snapped(_ ranges: [Range<Int>], in file: AVAudioFile, url: URL, rate: Double, total: Int) throws(RenderError) -> [Range<Int>] {
        let radius = max(Int(0.005 * rate), 1)
        var cache: [Int: Int] = [:]
        func snap(_ frame: Int) throws(RenderError) -> Int {
            guard frame > 0, frame < total else { return frame }
            if let known = cache[frame] { return known }
            let first = max(0, frame - radius - 1)
            let count = min(total, frame + radius + 1) - first
            let window = try read(file, url: url, from: first, count: count)
            let snapped = window.withUnsafeBufferPointer { bake.dsp.sliceSnap($0.baseAddress, first, window.count, frame, radius) }
            cache[frame] = snapped
            return snapped
        }
        var result: [Range<Int>] = []
        for range in ranges {
            let start = try snap(range.lowerBound), end = try snap(range.upperBound)
            if end > start { result.append(start..<end) }
        }
        return result
    }

    /// `count` frames from `first`, mixed to mono.
    private static func read(_ file: AVAudioFile, url: URL, from first: Int, count: Int) throws(RenderError) -> [Float] {
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return [] }
        file.framePosition = AVAudioFramePosition(first)
        do { try file.read(into: buffer, frameCount: AVAudioFrameCount(count)) } catch { throw .unreadableAsset(url) }
        guard let data = buffer.floatChannelData else { return [] }
        var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
        mixDown(data, channels: Int(file.processingFormat.channelCount), frames: Int(buffer.frameLength), into: &mono)
        return mono
    }

    private static func mixDown(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int, into mono: inout [Float]) {
        let scale = 1 / Float(max(channels, 1))
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += data[channel][frame] }
            mono[frame] = sum * scale
        }
    }
}
