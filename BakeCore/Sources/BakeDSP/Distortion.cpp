#include "BakeDSP/Distortion.h"
#include "BakeDSP/Oversampling.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

// The oversampling filter (design, interpolation reach, edge reads) is Oversampling.h's, shared with the Waveshaper,
// Wavefolder and Derivative Distortion, so the nodes agree by construction rather than by copy.
using namespace oversampling;

constexpr int tapsPerPhase = 64;        ///< filter reach: 32 base-rate frames each side

int clampFactor(int factor) noexcept { return clampOversampling(factor); }
int tapCount(int factor) noexcept { return tapsPerPhase * factor + 1; }

float shape(DistortionMode mode, float x, float gain, float ceiling) noexcept {
    const float driven = x * gain;
    return mode == DistortionMode::hard ? std::clamp(driven, -ceiling, ceiling)
                                        : ceiling * std::tanh(driven / ceiling);
}

float decibelsToGain(float decibels) noexcept { return std::pow(10.0f, decibels / 20.0f); }

} // namespace

std::size_t distortionScratchFloats(int oversampling, std::size_t maxCount) noexcept {
    const int factor = clampFactor(oversampling);
    if (factor == 1) {
        return 1;
    }
    const std::size_t length = static_cast<std::size_t>(tapCount(factor));
    return (maxCount + 1) * factor + 2 * length + length;
}

void renderDistortion(DistortionMode mode, int oversampling,
                      const ParameterSignal& drive, const ParameterSignal& ceiling, const ParameterSignal& mix,
                      const float* input, std::size_t inputFrames,
                      float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept {
    renderDistortion(mode, ParameterSignal(), oversampling, drive, ceiling, mix, input, inputFrames, output, frameOffset, count, scratch);
}

void renderDistortion(DistortionMode fixedMode, const ParameterSignal& modeIndex, int oversampling,
                      const ParameterSignal& drive, const ParameterSignal& ceiling, const ParameterSignal& mix,
                      const float* input, std::size_t inputFrames,
                      float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept {
    if (input == nullptr || output == nullptr || scratch == nullptr || count == 0) {
        return;
    }
    const int factor = clampFactor(oversampling);

    if (factor == 1) {
        for (std::size_t i = 0; i < count; ++i) {
            const std::size_t frame = frameOffset + i;
            const float dry = inputAt(input, inputFrames, static_cast<long long>(frame));
            const float wet = shape(choiceAt(modeIndex, frame, fixedMode, 2), dry, decibelsToGain(drive.valueAt(frame)), decibelsToGain(ceiling.valueAt(frame)));
            output[i] = dry + (wet - dry) * mix.valueAt(frame);
        }
        return;
    }

    const int length = tapCount(factor);
    const int center = length / 2;
    float* taps = scratch;
    float* high = scratch + length;
    designTaps(factor, taps);

    // High-rate indices needed to decimate frames [frameOffset, frameOffset + count).
    const long long firstHigh = static_cast<long long>(frameOffset) * factor - center;
    const long long highCount = static_cast<long long>(count - 1) * factor + 2 * center + 1;

    long long cachedFrame = -1;
    float gain = 1, limit = 1;
    DistortionMode mode = fixedMode;
    for (long long j = 0; j < highCount; ++j) {
        const long long m = firstHigh + j;
        // Interpolate: only every factor-th upsampled sample is non-zero (the input frames).
        const long long lowest = floorDivide(m + center - (length - 1) + factor - 1, factor);
        const long long highest = floorDivide(m + center, factor);
        double sum = 0;
        for (long long b = lowest; b <= highest; ++b) {
            sum += static_cast<double>(taps[m + center - b * factor]) * inputAt(input, inputFrames, b);
        }
        const float upsampled = static_cast<float>(sum * factor);

        const long long frame = std::max<long long>(0, floorDivide(m, factor));
        if (frame != cachedFrame) {
            gain = decibelsToGain(drive.valueAt(static_cast<std::size_t>(frame)));
            limit = decibelsToGain(ceiling.valueAt(static_cast<std::size_t>(frame)));
            mode = choiceAt(modeIndex, static_cast<std::size_t>(frame), fixedMode, 2);
            cachedFrame = frame;
        }
        high[j] = shape(mode, upsampled, gain, limit);
    }

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        double sum = 0;
        const long long base = static_cast<long long>(i) * factor;
        for (int k = 0; k < length; ++k) {
            sum += static_cast<double>(taps[k]) * high[base + 2 * center - k];
        }
        const float wet = static_cast<float>(sum);
        const float dry = inputAt(input, inputFrames, static_cast<long long>(frame));
        output[i] = dry + (wet - dry) * mix.valueAt(frame);
    }
}

} // namespace bake::dsp
