import AVFAudio
import BakeDSP
import BakeGraph
import Foundation

/// Audio node: loads its file, converts it to the project rate, then crops, loops, and applies gain
/// into its pool buffer.
final class AudioSourceProcessor: StepProcessor {
    private let outputs: [UnsafeMutableBufferPointer<Float>]
    /// The cropped region at the project rate, one array per channel.
    private let region: [[Float]]
    /// Gain in dB, possibly modulated from Page 2.
    private let gain: bake.dsp.ParameterSignal

    init(step: RenderStep, url: URL, sampleRate: Double, pool: BufferPool) throws {
        guard let binding = step.outputs["out"] else { throw RenderError.unsupportedNode(step.kind) }
        let source = try Self.load(url, at: sampleRate, interpolation: step.parameters["interpolation"])

        // Same arithmetic as SignalResolver, so the region fills the planned length exactly.
        let loops = max(Int((step.parameters["loopCount"]?.numberValue ?? 1).rounded()), 1)
        let regionLength = binding.shape.frames / loops
        let projectFrames = Double(source.frameCount) * sampleRate / source.sampleRate
        let regionStart = Int((projectFrames * (step.parameters["cropStart"]?.numberValue ?? 0)).rounded())

        region = source.channels.map { channel in
            let lower = min(regionStart, channel.count)
            let upper = min(regionStart + regionLength, channel.count)
            var samples = Array(channel[lower..<upper])
            // Pad with silence if conversion produced a few frames fewer than planned.
            samples.append(contentsOf: repeatElement(0, count: regionLength - samples.count))
            return samples
        }
        outputs = (0..<binding.shape.channels).map { pool.channel($0, of: binding) }
        gain = bake.dsp.ParameterSignal("gain", of: step, pool: pool)
    }

    func process(frames: Range<Int>) async throws {
        // Unmodulated gain is computed once, so 0 dB stays exactly ×1 (bit-exact pass-through).
        let constant: Float? = gain.modulation == nil ? Float(pow(10, Double(gain.base) / 20)) : nil
        for (output, samples) in zip(outputs, region) {
            for frame in frames {
                let level = constant ?? Float(pow(10, Double(gain.valueAt(frame)) / 20))
                output[frame] = samples[frame % samples.count] * level
            }
        }
    }

    func finish() throws -> PendingOutput? { nil }

    func discard() {}

    // MARK: - Loading

    private static func load(
        _ url: URL, at sampleRate: Double, interpolation: ParameterValue?
    ) throws -> (channels: [[Float]], frameCount: Int, sampleRate: Double) {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard let input = try readAll(file) else { throw RenderError.unreadableAsset(url) }

            let buffer: AVAudioPCMBuffer
            if format.sampleRate == sampleRate {
                buffer = input
            } else {
                buffer = try resample(input, to: sampleRate, interpolation: interpolation)
            }
            guard let data = buffer.floatChannelData else { throw RenderError.unreadableAsset(url) }
            let channels = (0..<Int(format.channelCount)).map {
                Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
            }
            return (channels, Int(file.length), format.sampleRate)
        } catch let error as RenderError {
            throw error
        } catch {
            throw RenderError.unreadableAsset(url)
        }
    }

    /// Reads the whole file into one buffer. A single `read(into:)` can return fewer frames than
    /// requested (seen with mono WAVs), so read in chunks until the file is exhausted.
    private static func readAll(_ file: AVAudioFile) throws -> AVAudioPCMBuffer? {
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        guard let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536),
              let destination = whole.floatChannelData else {
            return nil
        }
        while file.framePosition < file.length {
            try file.read(into: chunk)
            guard chunk.frameLength > 0, let source = chunk.floatChannelData else { break }
            let count = min(Int(chunk.frameLength), Int(total - whole.frameLength))
            for channel in 0..<Int(format.channelCount) {
                (destination[channel] + Int(whole.frameLength)).update(from: source[channel], count: count)
            }
            whole.frameLength += AVAudioFrameCount(count)
        }
        return whole
    }

    private static func resample(
        _ input: AVAudioPCMBuffer, to sampleRate: Double, interpolation: ParameterValue?
    ) throws -> AVAudioPCMBuffer {
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: input.format.channelCount),
              let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw CocoaError(.featureUnsupported)
        }
        // `sampleRateConverterQuality` is a plain Int: use AVAudioQuality's raw values, not `.min`/`.max`
        // (which would silently mean Int.min/Int.max).
        switch interpolation {
        case .choice("linear")?:
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter.sampleRateConverterQuality = AVAudioQuality.min.rawValue
        case .choice("hermite")?:
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        default: // "sinc"
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        }

        let expected = (Double(input.frameLength) * sampleRate / input.format.sampleRate).rounded(.up)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(expected) + 1_024) else {
            throw CocoaError(.featureUnsupported)
        }
        let source = SingleBufferSource(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in source.next(status) }
        if status == .error {
            throw error ?? CocoaError(.featureUnsupported)
        }
        return output
    }
}

/// Feeds AVAudioConverter one buffer, then end-of-stream.
/// `@unchecked Sendable`: the converter calls the input block synchronously on the converting thread.
private final class SingleBufferSource: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var delivered = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if delivered {
            status.pointee = .endOfStream
            return nil
        }
        delivered = true
        status.pointee = .haveData
        return buffer
    }
}
