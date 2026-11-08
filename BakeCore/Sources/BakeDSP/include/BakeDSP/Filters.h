#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class FilterType : int { lowpass = 0, highpass = 1, bandpass = 2, notch = 3 };

inline constexpr int maxFilterSections = 8;
/// Modulated coefficients update every this many frames, on absolute frame boundaries,
/// so chunking never changes the result.
inline constexpr std::size_t filterControlBlock = 32;

/// Normalized biquad (a0 = 1), RBJ Audio EQ Cookbook.
struct BiquadCoefficients {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
};

BiquadCoefficients biquadCoefficients(FilterType type, double cutoff, double q, double sampleRate) noexcept;

/// One channel's filter memory, carried across chunks.
struct FilterState {
    double z1[maxFilterSections] = {};
    double z2[maxFilterSections] = {};
    BiquadCoefficients coefficients;
    bool hasCoefficients = false;
};

/// Filters `count` samples of one channel through `sections` identical biquads.
/// `frameOffset` is the absolute frame of `input[0]`/`output[0]` (indexes modulation signals).
void renderFilter(FilterState* state, FilterType type, int sections,
                  const ParameterSignal& cutoff, const ParameterSignal& q, const ParameterSignal& drive,
                  double sampleRate, const float* input, float* output,
                  std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Type modulatable (an index in FilterType's order), taken with Cutoff and Q at each
/// control block.
void renderFilter(FilterState* state, FilterType type, const ParameterSignal& typeIndex, int sections,
                  const ParameterSignal& cutoff, const ParameterSignal& q, const ParameterSignal& drive,
                  double sampleRate, const float* input, float* output,
                  std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
