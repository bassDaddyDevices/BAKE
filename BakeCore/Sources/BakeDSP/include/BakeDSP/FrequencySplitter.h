#pragma once

#include <cstddef>

#include "BakeDSP/Filters.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

// Frequency Splitter: 2–5 bands that sum back to the input exactly. Splits are sorted each block;
// each band is a Linkwitz–Riley (two Butterworth biquads) lowpass of what the lower bands left over,
// and the last band is the remainder, so the sum is the input by construction.

inline constexpr int maxSplitterBands = 5;

struct FrequencySplitterControls {
    ParameterSignal split1; ///< Hz, 20–20000
    ParameterSignal split2;
    ParameterSignal split3;
    ParameterSignal split4;
    int bands = 3;          ///< 2–5 (fixed: it sets the pin count)
    double sampleRate = 48000;
};

/// Where each band goes; a null band (an unwired output) is computed but not written.
struct FrequencySplitterOutputs {
    float* bands[maxSplitterBands] = {};
};

/// One channel's carried state. Zero-initialise one per channel.
struct FrequencySplitterState {
    FilterState lowpass[maxSplitterBands - 1]; ///< two sections each
};

/// Splits `count` frames of one channel; `input` and every band pointer point at absolute frame
/// `frameOffset`.
void renderFrequencySplitter(FrequencySplitterState* state, const FrequencySplitterControls& controls,
                             const float* input, const FrequencySplitterOutputs& outputs,
                             std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
