#include "BakeDSP/Filters.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

BiquadCoefficients biquadCoefficients(FilterType type, double cutoff, double q, double sampleRate) noexcept {
    constexpr double pi = 3.141592653589793;
    const double w0 = 2 * pi * std::min(cutoff, 0.49 * sampleRate) / sampleRate;
    const double cosine = std::cos(w0);
    const double alpha = std::sin(w0) / (2 * q);
    const double a0 = 1 + alpha;
    double b0 = 1, b1 = 0, b2 = 0;
    switch (type) {
    case FilterType::lowpass:  b0 = (1 - cosine) / 2; b1 = 1 - cosine;    b2 = b0; break;
    case FilterType::highpass: b0 = (1 + cosine) / 2; b1 = -(1 + cosine); b2 = b0; break;
    case FilterType::bandpass: b0 = alpha;            b1 = 0;             b2 = -alpha; break; // 0 dB peak
    case FilterType::notch:    b0 = 1;                b1 = -2 * cosine;   b2 = 1; break;
    }
    return {b0 / a0, b1 / a0, b2 / a0, -2 * cosine / a0, (1 - alpha) / a0};
}

void renderFilter(FilterState* state, FilterType type, int sections,
                  const ParameterSignal& cutoff, const ParameterSignal& q, const ParameterSignal& drive,
                  double sampleRate, const float* input, float* output,
                  std::size_t frameOffset, std::size_t count) noexcept {
    renderFilter(state, type, ParameterSignal(), sections, cutoff, q, drive, sampleRate, input, output, frameOffset, count);
}

void renderFilter(FilterState* state, FilterType fixedType, const ParameterSignal& typeIndex, int sections,
                  const ParameterSignal& cutoff, const ParameterSignal& q, const ParameterSignal& drive,
                  double sampleRate, const float* input, float* output,
                  std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || input == nullptr || output == nullptr) {
        return;
    }
    const int stages = std::clamp(sections, 1, maxFilterSections);
    const bool modulated = cutoff.modulation != nullptr || q.modulation != nullptr || typeIndex.modulation != nullptr;
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        if (!state->hasCoefficients || (modulated && frame % filterControlBlock == 0)) {
            const FilterType type = choiceAt(typeIndex, frame, fixedType, 4);
            state->coefficients = biquadCoefficients(type, cutoff.valueAt(frame), q.valueAt(frame), sampleRate);
            state->hasCoefficients = true;
        }

        double x = input[i];
        const float driveDecibels = drive.valueAt(frame);
        if (driveDecibels > 0) {
            // Blend in tanh saturation by how far the drive knob is turned (0 dB = clean).
            const double gain = std::pow(10.0, driveDecibels / 20.0);
            x += (std::tanh(gain * x) - x) * (driveDecibels / drive.maximum);
        }

        const BiquadCoefficients& c = state->coefficients;
        for (int s = 0; s < stages; ++s) { // transposed direct form II
            const double y = c.b0 * x + state->z1[s];
            state->z1[s] = c.b1 * x - c.a1 * y + state->z2[s];
            state->z2[s] = c.b2 * x - c.a2 * y;
            x = y;
        }
        output[i] = static_cast<float>(x);
    }
}

} // namespace bake::dsp
