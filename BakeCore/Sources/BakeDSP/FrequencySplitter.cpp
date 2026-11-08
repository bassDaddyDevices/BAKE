#include "BakeDSP/FrequencySplitter.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr double butterworthQ = 0.7071067811865476;

inline double linkwitzRiley(FilterState& f, double x) noexcept {
    const BiquadCoefficients& c = f.coefficients;
    for (int s = 0; s < 2; ++s) {
        const double y = c.b0 * x + f.z1[s];
        f.z1[s] = c.b1 * x - c.a1 * y + f.z2[s];
        f.z2[s] = c.b2 * x - c.a2 * y;
        x = y;
    }
    return x;
}

} // namespace

void renderFrequencySplitter(FrequencySplitterState* state, const FrequencySplitterControls& controls,
                             const float* input, const FrequencySplitterOutputs& outputs,
                             std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || input == nullptr) {
        return;
    }
    const int bands = std::clamp(controls.bands, 2, maxSplitterBands);
    const int splits = bands - 1;
    const double rate = controls.sampleRate;
    const double highest = 0.45 * rate;
    const ParameterSignal* signals[] = {&controls.split1, &controls.split2, &controls.split3, &controls.split4};
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        if (frame % filterControlBlock == 0 || !state->lowpass[0].hasCoefficients) {
            const std::size_t block = frame - frame % filterControlBlock;
            double frequencies[maxSplitterBands - 1] = {};
            for (int k = 0; k < splits; ++k) {
                frequencies[k] = std::clamp(static_cast<double>(signals[k]->valueAt(block)), 20.0, highest);
            }
            std::sort(frequencies, frequencies + splits);
            for (int k = 1; k < splits; ++k) {
                // Keep splits at least 1% apart so no band collapses to nothing.
                frequencies[k] = std::max(frequencies[k], frequencies[k - 1] * 1.01);
            }
            for (int k = 0; k < splits; ++k) {
                state->lowpass[k].coefficients = biquadCoefficients(FilterType::lowpass, std::min(frequencies[k], highest), butterworthQ, rate);
                state->lowpass[k].hasCoefficients = true;
            }
        }
        // Each band is the lowpass of what the lower bands left; the last band is the remainder.
        float rest = std::isfinite(input[i]) ? input[i] : 0.0f;
        for (int k = 0; k < splits; ++k) {
            float band = static_cast<float>(linkwitzRiley(state->lowpass[k], rest));
            if (!std::isfinite(band)) {
                state->lowpass[k] = FilterState();
                band = 0;
            }
            if (outputs.bands[k] != nullptr) {
                outputs.bands[k][i] = band;
            }
            rest -= band;
        }
        if (outputs.bands[splits] != nullptr) {
            outputs.bands[splits][i] = rest;
        }
    }
}

} // namespace bake::dsp
