import AVFAudio
import BakeGraph
import Foundation

/// Reads a file's waveform summary in 64k-frame chunks, never the whole file at once.
public enum WaveformReader {
    /// `buckets` peaks across the file (fewer for files shorter than that), each the loudest
    /// absolute sample of any channel in its slice.
    public static func peaks(of url: URL, buckets: Int = 160) throws(RenderError) -> WaveformPeaks {
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = Int(file.length)
            guard frames > 0 else { return WaveformPeaks(peaks: []) }
            let count = min(max(buckets, 1), frames)
            var peaks = [Float](repeating: 0, count: count)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
                throw RenderError.unreadableAsset(url)
            }
            var position = 0
            while position < frames {
                try file.read(into: chunk)
                let read = Int(chunk.frameLength)
                guard read > 0, let channels = chunk.floatChannelData else { break }
                for channel in 0..<Int(chunk.format.channelCount) {
                    let samples = channels[channel]
                    for i in 0..<read {
                        let bucket = (position + i) * count / frames
                        peaks[bucket] = max(peaks[bucket], abs(samples[i]))
                    }
                }
                position += read
            }
            return WaveformPeaks(peaks: peaks)
        } catch let error as RenderError {
            throw error
        } catch {
            throw .unreadableAsset(url)
        }
    }
}
