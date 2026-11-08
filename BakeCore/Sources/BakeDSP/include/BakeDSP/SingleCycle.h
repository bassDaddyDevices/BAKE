#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class SingleCycleShape : int { sine = 0, triangle, saw, square, pulse, noise, additive };

/// Renders samples of repeated cycles. Modulation is read at each cycle's absolute first frame.
void renderSingleCycle(SingleCycleShape fixedShape, const ParameterSignal& shapeIndex, const ParameterSignal& width,
                       const ParameterSignal& phase, const ParameterSignal& warp, const ParameterSignal& morph,
                       const float* partials, std::size_t partialCount, std::uint64_t seed,
                       float* output, std::size_t frameSize, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Harmonic: 1…64 whole cycles per frame, read at each frame's start.
void renderSingleCycle(SingleCycleShape fixedShape, const ParameterSignal& shapeIndex, const ParameterSignal& width,
                       const ParameterSignal& phase, const ParameterSignal& warp, const ParameterSignal& morph,
                       const ParameterSignal& harmonic, const float* partials, std::size_t partialCount, std::uint64_t seed,
                       float* output, std::size_t frameSize, std::size_t frameOffset, std::size_t count) noexcept;

/// Carried between chunks in Oscillator mode.
struct SingleCycleOscillatorState {
    double phase = 0; ///< 0..<1, advanced by frequency / sampleRate each frame
};

/// Oscillator mode: a free-running cycle at `frequency` (Hz), every control read per frame. The shapes
/// are the exact (not band-limited) ones; use Additive for an alias-free tone at high pitches.
void renderSingleCycleOscillator(SingleCycleOscillatorState* state, SingleCycleShape fixedShape,
                                 const ParameterSignal& shapeIndex, const ParameterSignal& width,
                                 const ParameterSignal& phase, const ParameterSignal& warp, const ParameterSignal& morph,
                                 const ParameterSignal& frequency, const float* partials, std::size_t partialCount,
                                 std::uint64_t seed, double sampleRate, float* output, std::size_t frameOffset,
                                 std::size_t count) noexcept;

} // namespace bake::dsp
