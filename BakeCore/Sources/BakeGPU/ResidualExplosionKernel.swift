import Foundation
import Metal

/// How Residual Explosion simplifies the signal (the catalog's `mode` options, in order).
public enum ResidualExplosionMode: UInt32, Sendable {
    /// Quantise to 2^bits levels; the residual is the quantisation error.
    case collapse = 0
    /// Zero every sample below a threshold; the residual is the quiet material.
    case sparsify = 1
}

/// The Residual Explosion node's settings, in musical units.
public struct ResidualExplosionSettings: Equatable, Sendable {
    public var mode: ResidualExplosionMode
    /// 0…1: Collapse goes from 16 bits to 1; Sparsify's threshold from −72 dB to −6 dB.
    public var severity: Double
    /// 0…60 dB on the residual, before its tanh ceiling.
    public var residualGainDecibels: Double
    /// 0…1: the simplified signal's level; 0 solos the residual.
    public var body: Double
    /// 0 = dry input only, 1 = wet only.
    public var mix: Double

    public init(
        mode: ResidualExplosionMode = .collapse, severity: Double = 0.5, residualGainDecibels: Double = 18,
        body: Double = 1, mix: Double = 1
    ) {
        self.mode = mode
        self.severity = severity
        self.residualGainDecibels = residualGainDecibels
        self.body = body
        self.mix = mix
    }
}

/// Mirrors `ResidualFrame` in ResidualExplosion.metal: the settings at one frame, ready for the shader.
struct ResidualFrame: Equatable {
    var levels: Float
    var inverseLevels: Float
    var threshold: Float
    var gain: Float
    var body: Float
    var mix: Float
    var mode: UInt32
}

/// Mirrors `ResidualUniforms` in ResidualExplosion.metal.
struct ResidualUniforms {
    var frames: UInt32
    var channels: UInt32
    var inputOffset: UInt32
    var inputChannelStride: UInt32
    var outputOffset: UInt32
    var outputChannelStride: UInt32
    var perFrame: UInt32
}

/// Mirrors `ResidualOversampledUniforms` in ResidualExplosion.metal.
struct ResidualOversampledUniforms {
    var frames: UInt32
    var channels: UInt32
    var start: UInt32
    var inputFrames: UInt32
    var inputChannelStride: UInt32
    var outputChannelStride: UInt32
    var factor: UInt32
    var length: UInt32
    var highCount: UInt32
    var highStride: UInt32
    var tableStart: Int32
    var perFrame: UInt32
}

extension ResidualExplosionSettings {
    /// The shader's view of these settings: Severity mapped per mode and decibels made linear here,
    /// not on the GPU, so the shader and the tests share one rounding.
    var frame: ResidualFrame {
        let severity = min(max(severity, 0), 1)
        let levels = pow(2, 15 - 15 * severity) // 2^(bits − 1), bits = 16 − 15·severity
        return ResidualFrame(
            levels: Float(levels), inverseLevels: Float(1 / levels),
            threshold: Float(pow(10, (-72 + 66 * severity) / 20)),
            gain: Float(pow(10, min(max(residualGainDecibels, 0), 60) / 20)),
            body: Float(min(max(body, 0), 1)), mix: Float(min(max(mix, 0), 1)),
            mode: mode.rawValue
        )
    }
}

/// Modulated Residual Explosion controls: the settings at each frame.
public struct ResidualExplosionModulation {
    public let settingsAt: (Int) -> ResidualExplosionSettings

    public init(settingsAt: @escaping (Int) -> ResidualExplosionSettings) {
        self.settingsAt = settingsAt
    }
}

/// Residual Explosion on the GPU engine. Stateless per sample: modulated or not, oversampled or not,
/// splitting a render into chunks never changes the sound. Oversampled, it runs the CPU nodes'
/// oversampler on the GPU: pass 1 interpolates and shapes every upsampled sample a sub-chunk needs,
/// pass 2 filters, decimates and mixes.
public final class ResidualExplosionKernel {
    /// Frames per GPU pass; bounds the per-frame settings table and the upsampled rows.
    public static let subChunkFrames = 4_096
    /// Settings-table frames on each side of a sub-chunk: pass 1 reads up to 32 frames past either end.
    static let tableMargin = 34

    private let gpu: GPUContext
    private let channels: Int
    private let factor: Int
    private let modulation: ResidualExplosionModulation?
    /// One frame of settings, or one per frame of a sub-chunk (with margins) when modulated.
    private let table: any MTLBuffer
    private let tableEntries: Int
    /// Oversampled only: the filter taps and the upsampled rows, one per channel.
    private let taps: (any MTLBuffer)?
    private let high: (any MTLBuffer)?
    private let highStride: Int

    public init(
        gpu: GPUContext, settings: ResidualExplosionSettings, channels: Int, oversampling: Int = 1,
        modulation: ResidualExplosionModulation? = nil
    ) throws(GPUError) {
        self.gpu = gpu
        self.channels = channels
        self.factor = min(max(oversampling, 1), OversamplingFilter.maxFactor)
        self.modulation = modulation
        tableEntries = modulation == nil ? 1 : Self.subChunkFrames + 2 * Self.tableMargin
        let length = tableEntries * MemoryLayout<ResidualFrame>.stride
        guard let table = gpu.device.makeBuffer(length: length, options: .storageModeShared) else {
            throw .allocationFailed(bytes: length)
        }
        table.contents().bindMemory(to: ResidualFrame.self, capacity: tableEntries)[0] = settings.frame
        self.table = table
        if factor > 1 {
            let coefficients = OversamplingFilter.taps(factor: factor)
            let tapBuffer = try gpu.makeSharedBuffer(floatCount: coefficients.count)
            tapBuffer.contents().bindMemory(to: Float.self, capacity: coefficients.count)
                .update(from: coefficients, count: coefficients.count)
            taps = tapBuffer
            highStride = (Self.subChunkFrames - 1) * factor + coefficients.count
            high = try gpu.makeSharedBuffer(floatCount: highStride * channels)
        } else {
            taps = nil
            high = nil
            highStride = 0
        }
    }

    /// Renders `frames` of planar `input` into the same frames of planar `output`.
    public func process(
        input: any MTLBuffer, inputChannelStride: Int,
        output: any MTLBuffer, outputChannelStride: Int,
        frames: Range<Int>
    ) async throws(GPUError) {
        let pipeline = gpu.pipeline("residualExplosion")
        var start = frames.lowerBound
        while start < frames.upperBound {
            let count = min(Self.subChunkFrames, frames.upperBound - start)
            // Oversampled, table[0] is frame start − margin; otherwise it is frame start.
            let tableStart = factor > 1 ? start - Self.tableMargin : start
            if let modulation {
                // Safe to rewrite: the previous sub-chunk's command buffer has completed.
                let entries = table.contents().bindMemory(to: ResidualFrame.self, capacity: tableEntries)
                let used = factor > 1 ? count + 2 * Self.tableMargin : count
                for index in 0..<used {
                    entries[index] = modulation.settingsAt(max(tableStart + index, 0)).frame
                }
            }
            if factor > 1 {
                try await processOversampled(
                    input: input, inputChannelStride: inputChannelStride,
                    output: output, outputChannelStride: outputChannelStride,
                    start: start, count: count, tableStart: tableStart
                )
                start += count
                continue
            }
            var uniforms = ResidualUniforms(
                frames: UInt32(count), channels: UInt32(channels),
                inputOffset: UInt32(start), inputChannelStride: UInt32(inputChannelStride),
                outputOffset: UInt32(start), outputChannelStride: UInt32(outputChannelStride),
                perFrame: modulation == nil ? 0 : 1
            )
            let commandBuffer = try gpu.makeCommandBuffer()
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw .commandFailed }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
            encoder.setBuffer(table, offset: 0, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<ResidualUniforms>.size, index: 3)
            encoder.dispatchThreads(
                MTLSize(width: count, height: channels, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, count), height: 1, depth: 1)
            )
            encoder.endEncoding()
            try await gpu.run(commandBuffer)
            start += count
        }
    }

    /// Both oversampled passes for one sub-chunk, in one encoder so pass 2 sees pass 1's rows.
    private func processOversampled(
        input: any MTLBuffer, inputChannelStride: Int,
        output: any MTLBuffer, outputChannelStride: Int,
        start: Int, count: Int, tableStart: Int
    ) async throws(GPUError) {
        guard let taps, let high else { return }
        let length = 64 * factor + 1
        let highCount = (count - 1) * factor + length
        var uniforms = ResidualOversampledUniforms(
            frames: UInt32(count), channels: UInt32(channels), start: UInt32(start),
            inputFrames: UInt32(inputChannelStride), inputChannelStride: UInt32(inputChannelStride),
            outputChannelStride: UInt32(outputChannelStride), factor: UInt32(factor), length: UInt32(length),
            highCount: UInt32(highCount), highStride: UInt32(highStride), tableStart: Int32(tableStart),
            perFrame: modulation == nil ? 0 : 1
        )
        let commandBuffer = try gpu.makeCommandBuffer()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw .commandFailed }
        let up = gpu.pipeline("residualExplosionUp")
        encoder.setComputePipelineState(up)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(high, offset: 0, index: 1)
        encoder.setBuffer(table, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<ResidualOversampledUniforms>.size, index: 3)
        encoder.setBuffer(taps, offset: 0, index: 4)
        encoder.dispatchThreads(
            MTLSize(width: highCount, height: channels, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(up.maxTotalThreadsPerThreadgroup, highCount), height: 1, depth: 1)
        )
        // Same (serial) encoder, so pass 2 runs after pass 1 and sees its rows.
        let down = gpu.pipeline("residualExplosionDown")
        encoder.setComputePipelineState(down)
        encoder.setBuffer(output, offset: 0, index: 5)
        encoder.dispatchThreads(
            MTLSize(width: count, height: channels, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(down.maxTotalThreadsPerThreadgroup, count), height: 1, depth: 1)
        )
        encoder.endEncoding()
        try await gpu.run(commandBuffer)
    }
}
