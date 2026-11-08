import BakeGraph
import Foundation
import Testing
@testable import BakeCanvas

/// The lane must show what the renderer does (BakeDSP's ParameterSignal: base + trim × mod × span,
/// base × (max/min)^(trim × mod) when exponential, then clamped; choices round the index).
struct ModulationRangeTests {
    private func parameter(_ kind: NodeKind, _ id: ParameterID) -> ParameterDefinition {
        NodeCatalog.definition(for: kind).parameter(id)!
    }

    @Test func linearNumbersMoveByTrimTimesTheSpan() {
        // Mix 0…1 at 0.5, trim 0.25: ±0.25.
        let range = ModulationRange(parameter: parameter(.chorus, "mix"), value: .number(0.5), trim: 0.25)
        #expect(range.value(at: 1) == 0.75 && range.value(at: -1) == 0.25 && range.value(at: 0) == 0.5)
        #expect(range.possible == 0.25...0.75)
    }

    @Test func exponentialNumbersMoveInOctavesOfTheRange() {
        // Cutoff 20…20000 Hz is a 1000× range; at 1 kHz with trim 0.1, +1 is 1000^0.1 ≈ 1.995×.
        let range = ModulationRange(parameter: parameter(.filters, "cutoff"), value: .number(1_000), trim: 0.1)
        #expect(abs(range.value(at: 1) - 1_000 * pow(1_000, 0.1)) < 1e-6)
        #expect(abs(range.value(at: -1) - 1_000 / pow(1_000, 0.1)) < 1e-6)
    }

    @Test func valuesClampAndNegativeTrimFlips() {
        let range = ModulationRange(parameter: parameter(.chorus, "mix"), value: .number(0.9), trim: -1)
        #expect(range.value(at: -1) == 1 && range.value(at: 1) == 0)
        #expect(range.possible == 0...1)
    }

    @Test func choicesMoveByOptionsAndRound() {
        // LFO Shape has 5 options; at Triangle (1) with trim 0.5, +1 is 1 + 0.5 × 4 = 3 (Square).
        let range = ModulationRange(parameter: parameter(.lfo, "shape"), value: .choice("triangle"), trim: 0.5)
        #expect(range.base == 1 && range.value(at: 1) == 3 && range.value(at: -1) == 0)
        #expect(range.value(at: 0.3) == 2)    // 1 + 0.6 rounds to 2
    }

    @Test func wholeNumberParametersRound() {
        let range = ModulationRange(parameter: parameter(.stepFX, "rotate"), value: .number(0), trim: 0.1)
        #expect(range.value(at: 0.3) == 2)    // 0.1 × 0.3 × 64 = 1.92 → 2
    }

    @Test func aBakedTraceGivesWhereItWent() {
        let range = ModulationRange(parameter: parameter(.chorus, "mix"), value: .number(0.5), trim: 0.5)
        #expect(range.swept([]) == nil)
        let swept = range.swept([0, 0.2, -0.4, .nan])
        #expect(abs((swept?.lowerBound ?? 0) - 0.3) < 1e-6 && abs((swept?.upperBound ?? 0) - 0.6) < 1e-6)
    }
}
