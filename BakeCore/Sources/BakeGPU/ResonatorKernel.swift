import Foundation
import Metal

/// Mirrors `ResonatorBand` in Resonator.metal.
struct ResonatorBandParameters {
    var delay: Float
    var feedback: Float
    var active: UInt32
}

/// Mirrors `ResonatorUniforms` in Resonator.metal.
struct ResonatorUniforms {
    var bands: UInt32
    var channels: UInt32
    var frames: UInt32
    var delayCapacity: UInt32
    var inputOffset: UInt32
    var inputChannelStride: UInt32
    var outputOffset: UInt32
    var outputChannelStride: UInt32
    var rowCapacity: UInt32
    var damping: Float
    var saturation: Float
    var normalization: Float
    var dcBlockerPole: Float
    var wet: Float             // 0 = dry, 1 = resonance only; keep last, mirrors the shader
}

/// Floats of carried loop-filter state per line; mirrors `LoopState` in Resonator.metal.
let resonatorLoopStateFloats = 3

/// Modulated Resonator controls: the settings at a frame (Root, Fine, Decay, Inharmonicity and Mix may
/// move; the rest stay as they were), read at the start of every `blockFrames` block.
public struct ResonatorModulation {
    public static let blockFrames = 64
    public let settingsAt: (Int) -> ResonatorSettings

    public init(settingsAt: @escaping (Int) -> ResonatorSettings) {
        self.settingsAt = settingsAt
    }

    /// The longest delay any modulated tuning can need: the lowest Root (20 Hz) at Fine −100 cents.
    static func delayCapacity(sampleRate: Double) -> Int {
        Int((sampleRate / (20 * pow(2, -100.0 / 1_200))).rounded(.up)) + 2
    }
}

/// The Resonator on the GPU engine: one comb delay line per (channel, band), kept in GPU memory
/// across chunks so splitting a render into chunks never changes the sound.
public final class ResonatorKernel {
    /// Frames per GPU pass; bounds the per-band scratch rows.
    public static let subChunkFrames = 4_096

    private let gpu: GPUContext
    private let channels: Int
    private let bandCount: Int
    private let delayCapacity: Int
    private let damping: Float
    private let saturation: Float
    private let normalization: Float
    private let wet: Float
    private let bandTable: any MTLBuffer
    private let delayLines: any MTLBuffer
    private let writeHeads: any MTLBuffer
    private let loopStates: any MTLBuffer
    private let rows: any MTLBuffer
    private let sampleRate: Double
    private let modulation: ResonatorModulation?
    /// Per-block band tables and per-frame gains for one sub-chunk, when modulated.
    private let blockTables: (any MTLBuffer)?
    private let wetGains: (any MTLBuffer)?
    private let dryGains: (any MTLBuffer)?

    public init(
        gpu: GPUContext, settings: ResonatorSettings, sampleRate: Double, channels: Int,
        modulation: ResonatorModulation? = nil
    ) throws(GPUError) {
        let tunings = ResonatorTuning.bands(for: settings, sampleRate: sampleRate)
        let lines = tunings.count * channels
        self.gpu = gpu
        self.channels = channels
        self.bandCount = tunings.count
        self.delayCapacity = modulation == nil
            ? ResonatorTuning.delayCapacity(for: tunings)
            : max(ResonatorTuning.delayCapacity(for: tunings), ResonatorModulation.delayCapacity(sampleRate: sampleRate))
        self.sampleRate = sampleRate
        self.modulation = modulation
        self.damping = Float(settings.damping)
        self.saturation = Float(settings.saturation)
        self.normalization = 1 / Float(max(tunings.filter(\.isActive).count, 1))
        self.wet = Float(min(max(settings.mix, 0), 1))

        // State buffers start zeroed (makeSharedBuffer zeroes them): silent lines, heads at 0.
        delayLines = try gpu.makeSharedBuffer(floatCount: lines * delayCapacity)
        writeHeads = try gpu.makeSharedBuffer(floatCount: lines) // UInt32 zero == Float zero bits
        loopStates = try gpu.makeSharedBuffer(floatCount: lines * resonatorLoopStateFloats)
        rows = try gpu.makeSharedBuffer(floatCount: lines * Self.subChunkFrames)

        let table = tunings.map {
            ResonatorBandParameters(delay: $0.delay, feedback: $0.feedback, active: $0.isActive ? 1 : 0)
        }
        let tableLength = table.count * MemoryLayout<ResonatorBandParameters>.stride
        guard let bandTable = gpu.device.makeBuffer(bytes: table, length: tableLength, options: .storageModeShared) else {
            throw .allocationFailed(bytes: tableLength)
        }
        self.bandTable = bandTable
        if modulation != nil {
            let blocks = (Self.subChunkFrames + ResonatorModulation.blockFrames - 1) / ResonatorModulation.blockFrames + 1
            let length = blocks * tunings.count * MemoryLayout<ResonatorBandParameters>.stride
            guard let tables = gpu.device.makeBuffer(length: length, options: .storageModeShared) else {
                throw .allocationFailed(bytes: length)
            }
            blockTables = tables
            wetGains = try gpu.makeSharedBuffer(floatCount: Self.subChunkFrames)
            dryGains = try gpu.makeSharedBuffer(floatCount: Self.subChunkFrames)
        } else {
            blockTables = nil
            wetGains = nil
            dryGains = nil
        }
    }

    /// Fills the sub-chunk's block tables and gains from the modulated settings.
    private func prepareModulated(start: Int, count: Int) {
        guard let modulation, let blockTables, let wetGains, let dryGains else { return }
        let tables = blockTables.contents().bindMemory(to: ResonatorBandParameters.self, capacity: blockTables.length / MemoryLayout<ResonatorBandParameters>.stride)
        let wet = wetGains.contents().bindMemory(to: Float.self, capacity: Self.subChunkFrames)
        let dry = dryGains.contents().bindMemory(to: Float.self, capacity: Self.subChunkFrames)
        // Blocks sit on absolute frames: block b of this sub-chunk starts at frame (start / blockFrames + b) × blockFrames.
        let blockFrames = ResonatorModulation.blockFrames
        let phase = start % blockFrames
        var block = 0
        while block * blockFrames < count + phase {
            let settings = modulation.settingsAt(start - phase + block * blockFrames)
            let tunings = ResonatorTuning.bands(for: settings, sampleRate: sampleRate)
            let limit = Float(max(delayCapacity - 2, 2))
            for (index, tuning) in tunings.prefix(bandCount).enumerated() {
                // A tuning whose delay no longer fits is silenced rather than read out of bounds.
                tables[block * bandCount + index] = ResonatorBandParameters(
                    delay: min(tuning.delay, limit), feedback: tuning.feedback, active: tuning.isActive && tuning.delay <= limit ? 1 : 0
                )
            }
            let normalization = 1 / Float(max(tunings.filter(\.isActive).count, 1))
            for frame in max(block * blockFrames - phase, 0)..<min((block + 1) * blockFrames - phase, count) {
                let mix = Float(min(max(modulation.settingsAt(start + frame).mix, 0), 1))
                wet[frame] = normalization * mix
                dry[frame] = 1 - mix
            }
            block += 1
        }
    }

    /// Renders `frames` of planar `input` into the same frames of planar `output`.
    /// Ranges must be consecutive across calls; state carries over.
    public func process(
        input: any MTLBuffer, inputChannelStride: Int,
        output: any MTLBuffer, outputChannelStride: Int,
        frames: Range<Int>
    ) async throws(GPUError) {
        var start = frames.lowerBound
        while start < frames.upperBound {
            let count = min(Self.subChunkFrames, frames.upperBound - start)
            var uniforms = ResonatorUniforms(
                bands: UInt32(bandCount), channels: UInt32(channels), frames: UInt32(count),
                delayCapacity: UInt32(delayCapacity),
                inputOffset: UInt32(start), inputChannelStride: UInt32(inputChannelStride),
                outputOffset: UInt32(start), outputChannelStride: UInt32(outputChannelStride),
                rowCapacity: UInt32(Self.subChunkFrames),
                damping: damping, saturation: saturation, normalization: normalization,
                dcBlockerPole: ResonatorTuning.dcBlockerPole, wet: wet
            )
            let commandBuffer = try gpu.makeCommandBuffer()
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw .commandFailed }
            if modulation != nil {
                prepareModulated(start: start, count: count)
            }

            // Pass 1: one thread per (channel, band).
            let bands = gpu.pipeline(modulation == nil ? "resonatorBands" : "resonatorBandsBlocked")
            let lines = bandCount * channels
            encoder.setComputePipelineState(bands)
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(rows, offset: 0, index: 1)
            encoder.setBuffer(delayLines, offset: 0, index: 2)
            encoder.setBuffer(writeHeads, offset: 0, index: 3)
            encoder.setBuffer(loopStates, offset: 0, index: 4)
            encoder.setBuffer(blockTables ?? bandTable, offset: 0, index: 5)
            encoder.setBytes(&uniforms, length: MemoryLayout<ResonatorUniforms>.size, index: 6)
            var blocks = SIMD2<UInt32>(UInt32(ResonatorModulation.blockFrames), UInt32(start % ResonatorModulation.blockFrames))
            if modulation != nil {
                encoder.setBytes(&blocks, length: MemoryLayout<SIMD2<UInt32>>.size, index: 7)
            }
            encoder.dispatchThreads(
                MTLSize(width: lines, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(bands.maxTotalThreadsPerThreadgroup, lines), height: 1, depth: 1)
            )

            // Pass 2: one thread per (frame, channel). Same encoder, so it runs after pass 1.
            let mix = gpu.pipeline(modulation == nil ? "resonatorMix" : "resonatorMixGained")
            encoder.setComputePipelineState(mix)
            encoder.setBuffer(rows, offset: 0, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<ResonatorUniforms>.size, index: 2)
            encoder.setBuffer(input, offset: 0, index: 3)
            if let wetGains, let dryGains {
                encoder.setBuffer(wetGains, offset: 0, index: 4)
                encoder.setBuffer(dryGains, offset: 0, index: 5)
            }
            encoder.dispatchThreads(
                MTLSize(width: count, height: channels, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(mix.maxTotalThreadsPerThreadgroup, count), height: 1, depth: 1)
            )
            encoder.endEncoding()
            try await gpu.run(commandBuffer)
            start += count
        }
    }
}
