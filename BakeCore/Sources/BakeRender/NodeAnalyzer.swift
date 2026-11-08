import BakeDSP
import BakeGraph

/// Summarises a finished node output (waveform envelope and spectrogram) straight from the render's
/// buffers, for the cards. Reads whole channels, so the render's chunk size cannot change it.
enum NodeAnalyzer {
    static let slices = 160
    static let spectrogramRows = 48

    static func isControl(_ pin: PinID, of kind: NodeKind) -> Bool {
        NodeCatalog.outputSignal(pin, of: kind) == .control
    }

    static func summarize(_ binding: BufferBinding, isControl: Bool, sampleRate: Double, pool: BufferPool) -> NodeSummary? {
        let frames = binding.shape.frames
        let channels = binding.shape.channels
        guard frames > 0, channels > 0 else { return nil }
        let pointers: [UnsafePointer<Float>?] = (0..<channels).map { UnsafePointer(pool.channel($0, of: binding).baseAddress) }

        let buckets = min(slices, frames)
        var minimums = [Float](repeating: 0, count: buckets)
        var maximums = [Float](repeating: 0, count: buckets)
        var rms = [Float](repeating: 0, count: buckets)
        pointers.withUnsafeBufferPointer { channelPointers in
            bake.dsp.summarizeEnvelope(channelPointers.baseAddress, channels, frames, buckets, &minimums, &maximums, &rms)
        }

        var spectrogram: Spectrogram?
        if !isControl {
            var values = [UInt8](repeating: 0, count: slices * spectrogramRows)
            var scratch = [Double](repeating: 0, count: bake.dsp.spectrogramScratchCount())
            pointers.withUnsafeBufferPointer { channelPointers in
                bake.dsp.analyzeSpectrogram(
                    channelPointers.baseAddress, channels, frames, sampleRate, slices, spectrogramRows, &values, &scratch
                )
            }
            spectrogram = Spectrogram(columns: slices, rows: spectrogramRows, values: values)
        }
        // Control signals are mono; their first seconds in detail let the cards show single bangs.
        var detail: [Float] = []
        if isControl, let first = pointers.first ?? nil {
            detail = NodeSummary.detailTrace(of: UnsafeBufferPointer(start: first, count: frames), sampleRate: sampleRate)
        }
        return NodeSummary(
            sampleRate: sampleRate, frames: frames, channels: channels, isControl: isControl,
            minimums: minimums, maximums: maximums, rms: rms, spectrogram: spectrogram, detail: detail
        )
    }
}
