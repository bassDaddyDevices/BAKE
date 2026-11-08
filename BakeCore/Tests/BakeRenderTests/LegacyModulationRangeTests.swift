import BakeDSP
import Foundation
import Testing
@testable import BakeGPU
@testable import BakeGraph
@testable import BakeRender

/// Widening a modulated parameter's catalog range changes how far a wired signal moves it, so documents saved
/// before the change must keep the old range (D-019). The values below are the ranges as they were before.
struct LegacyModulationRangeTests {
    private func signal(_ kind: NodeKind, _ id: String, marker: String, base: Double? = nil) throws -> bake.dsp.ParameterSignal {
        var parameters = NodeCatalog.defaultParameters(for: kind)
        parameters[LegacyModulationRanges.parameterID] = .choice(marker)
        if let base { parameters[id] = .number(base) }
        let step = RenderStep(
            node: NodeID(UUID()), kind: kind, parameters: parameters, modulationTrims: [:], assetID: nil,
            shape: SignalShape(frames: 100, channels: 1), inputs: [:], outputs: [:]
        )
        return bake.dsp.ParameterSignal(id, of: step, pool: try BufferPool(capacities: [1], gpu: GPUContext()))
    }

    /// The signal's value for a modulation sample of `amount`.
    private func value(_ signal: bake.dsp.ParameterSignal, at amount: Float) -> Float {
        var moved = signal
        let samples = [amount]
        return samples.withUnsafeBufferPointer { pointer in
            moved.modulation = pointer.baseAddress
            moved.modulationFrames = 1
            return moved.valueAt(0)
        }
    }

    @Test func legacyGranularAndStutterUseTheOldRangesAndScales() throws {
        let size = try signal(.granularCloud, "size", marker: "legacy", base: 80)
        #expect(size.minimum == 5 && size.maximum == 500 && size.scale == .linear)
        #expect(abs(value(size, at: 0.25) - (80 + 0.25 * 495)) < 1e-3)

        let density = try signal(.granularCloud, "density", marker: "legacy", base: 25)
        #expect(density.minimum == 1 && density.maximum == 200 && density.scale == .exponential)
        #expect(abs(value(density, at: 0.25) - 25 * Float(pow(200.0, 0.25))) < 1e-2)

        let spray = try signal(.granularCloud, "spray", marker: "legacy", base: 100)
        #expect(spray.minimum == 0 && spray.maximum == 2_000 && spray.scale == .linear)
        #expect(abs(value(spray, at: 0.5) - (100 + 0.5 * 2_000)) < 1e-3)

        let delay = try signal(.flanger, "delay", marker: "legacy", base: 4)
        #expect(delay.minimum == 0.1 && delay.maximum == 15 && delay.scale == .exponential)
        #expect(abs(value(delay, at: 0.5) - min(4 * Float(pow(150.0, 0.5)), 15)) < 1e-3)

        let repeats = try signal(.stutter, "repeats", marker: "legacy", base: 8)
        #expect(repeats.minimum == 1 && repeats.maximum == 64 && repeats.scale == .linear)
        #expect(abs(value(repeats, at: 0.5) - (8 + 0.5 * 63)) < 1e-3)
    }

    @Test func newNodesUseTheWideRanges() throws {
        let size = try signal(.granularCloud, "size", marker: "current", base: 80)
        #expect(size.minimum == 5 && size.maximum == 2_000 && size.scale == .exponential)
        let density = try signal(.granularCloud, "density", marker: "current", base: 25)
        #expect(density.minimum == 1 && density.maximum == 1_000)
        let spray = try signal(.granularCloud, "spray", marker: "current", base: 100)
        #expect(spray.minimum == 0 && spray.maximum == 10_000)
        let delay = try signal(.flanger, "delay", marker: "current", base: 4)
        #expect(delay.minimum == 0.1 && delay.maximum == 50)
        let repeats = try signal(.stutter, "repeats", marker: "current", base: 8)
        #expect(repeats.minimum == 1 && repeats.maximum == 256)
    }

    @Test func theMarkOnlyChangesParametersWithAnEntry() throws {
        let mix = try signal(.granularCloud, "mix", marker: "legacy")
        let reference = try signal(.granularCloud, "mix", marker: "current")
        #expect(mix.minimum == reference.minimum && mix.maximum == reference.maximum && mix.scale == reference.scale)
    }

    @Test func theMarkIsStoredButNeverDrawn() {
        for kind in [NodeKind.granularCloud, .stutter, .flanger] {
            let definition = NodeCatalog.definition(for: kind).parameter(LegacyModulationRanges.parameterID)
            #expect(definition?.role == .hidden && definition?.isModulatable == false)
        }
    }
}
