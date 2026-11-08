import AVFAudio
import BakeGraph
import Foundation

/// Print node: streams its input from the pool into a hidden temporary WAV next to the destination.
/// The engine moves it into place only after the whole render succeeds.
final class PrintProcessor: StepProcessor {
    private let inputs: [UnsafeMutableBufferPointer<Float>]
    private let chunk: AVAudioPCMBuffer
    private let temporaryURL: URL
    private let finalURL: URL
    private var file: AVAudioFile?
    /// The patch to carry inside the WAV (Bake nodes only; Preview renders are temporary).
    private let workflow: BakedWorkflow?
    /// Wavetable metadata is an optional Bake-only WAV chunk.
    private let wavetableFrameSize: Int?
    /// With Clean Up on, the render goes to a 32-bit float scratch file, and `finish` writes the real one.
    private let cleanUp: CleanUp?
    private let scratchURL: URL?
    private let fileSettings: [String: Any]

    init(step: RenderStep, finalURL: URL, sampleRate: Double, maxChunkFrames: Int, pool: BufferPool, workflow: BakedWorkflow? = nil) throws {
        guard let binding = step.inputs["in"],
              let format = Self.format(sampleRate: sampleRate, channels: binding.shape.channels),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxChunkFrames)) else {
            throw RenderError.writeFailed(finalURL)
        }
        self.inputs = (0..<binding.shape.channels).map { pool.channel($0, of: binding) }
        self.chunk = chunk
        self.finalURL = finalURL
        self.workflow = workflow
        if case .choice(let frameSize)? = step.parameters["wavetable"], frameSize != "off" {
            wavetableFrameSize = Int(frameSize)
        } else {
            wavetableFrameSize = nil
        }
        // Hidden and unique, but still ending in .wav so AVAudioFile picks the WAVE container.
        self.temporaryURL = finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.wav"
        )
        fileSettings = Self.settings(for: step, sampleRate: sampleRate, channels: binding.shape.channels)
        cleanUp = CleanUp(parameters: step.parameters, sampleRate: sampleRate)
        scratchURL = cleanUp == nil ? nil : temporaryURL.deletingPathExtension().appendingPathExtension("scratch.wav")
        do {
            var settings = fileSettings
            if cleanUp != nil {
                settings[AVLinearPCMBitDepthKey] = 32
                settings[AVLinearPCMIsFloatKey] = true
            }
            file = try AVAudioFile(
                forWriting: scratchURL ?? temporaryURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
            )
        } catch {
            try? FileManager.default.removeItem(at: scratchURL ?? temporaryURL)
            throw RenderError.writeFailed(finalURL)
        }
    }

    func process(frames: Range<Int>) async throws {
        guard let file, let destination = chunk.floatChannelData else { throw RenderError.writeFailed(finalURL) }
        chunk.frameLength = AVAudioFrameCount(frames.count)
        for (channel, input) in inputs.enumerated() {
            guard let source = input.baseAddress else { continue }
            destination[channel].update(from: source + frames.lowerBound, count: frames.count)
        }
        do {
            try file.write(from: chunk)
        } catch {
            throw RenderError.writeFailed(finalURL)
        }
    }

    func finish() throws -> PendingOutput? {
        file?.close()
        file = nil
        if let cleanUp, let scratchURL {
            defer { try? FileManager.default.removeItem(at: scratchURL) }
            do {
                let output = try AVAudioFile(forWriting: temporaryURL, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try cleanUp.apply(scratch: scratchURL, to: output)
                output.close()
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw RenderError.writeFailed(finalURL)
            }
        }
        // Metadata appends happen only after AVAudioFile has finalized the WAV. The optional
        // wavetable declaration precedes the workflow chunk, which remains last for drag-and-drop.
        if let wavetableFrameSize { try? WavetableChunk.append(toWAV: temporaryURL, frameSize: wavetableFrameSize) }
        try? workflow?.append(toWAV: temporaryURL)
        return PendingOutput(temporaryURL: temporaryURL, finalURL: finalURL)
    }

    func discard() {
        file?.close()
        file = nil
        try? FileManager.default.removeItem(at: temporaryURL)
        if let scratchURL { try? FileManager.default.removeItem(at: scratchURL) }
    }

    /// Deinterleaved float at the project rate. Formats with more than two channels need a channel
    /// layout (AVFAudio returns nil without one); BAKE's channels have no speaker roles, so they're
    /// discrete, in order.
    private static func format(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        }
        return discreteLayout(channels).map { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: $0) }
    }

    private static func discreteLayout(_ channels: Int) -> AVAudioChannelLayout? {
        AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))
    }

    /// WAV settings for the node's bit depth: 16 or 24-bit integer, or 32-bit float.
    private static func settings(for step: RenderStep, sampleRate: Double, channels: Int) -> [String: Any] {
        var bitDepth = "24"
        if case .choice(let value)? = step.parameters["bitDepth"] {
            bitDepth = value
        }
        let isFloat = bitDepth == "32f"
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: isFloat ? 32 : (Int(bitDepth) ?? 24),
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if channels > 2, let layout = discreteLayout(channels) {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }
}
