#include "BakeDSP/EnvelopeFollower.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

// Attack and Release arrive in milliseconds, the catalog's unit, clamped to its ranges.
constexpr double minimumAttackMilliseconds = 0.1;
constexpr double maximumAttackMilliseconds = 500.0;
constexpr double minimumReleaseMilliseconds = 1.0;
constexpr double maximumReleaseMilliseconds = 5000.0;
constexpr double rmsWindowSeconds = 0.05;

/// One-pole coefficient for a time constant in milliseconds.
double smoothing(double milliseconds, double sampleRate) noexcept {
    return std::exp(-1.0 / (milliseconds * 0.001 * sampleRate));
}

} // namespace

void renderEnvelopeFollower(EnvelopeFollowerState* state, EnvelopeFollowerDetection detection,
                            const AudioInput& input, const ParameterSignal& attack,
                            const ParameterSignal& release, const ParameterSignal& gain,
                            double sampleRate, float* output, std::size_t frameOffset,
                            std::size_t count) noexcept {
    if (state == nullptr || output == nullptr || !(sampleRate > 0.0) || !std::isfinite(sampleRate)) {
        return;
    }
    const std::size_t channels = std::min(input.channelCount, maxAudioInputChannels);
    const double rmsCoefficient = std::exp(-1.0 / (rmsWindowSeconds * sampleRate));
    // Coefficients are recomputed only when their parameter changes (it rarely does, sample to sample).
    float lastAttack = -1, lastRelease = -1, lastGain = 1e9f;
    double attackCoefficient = 0, releaseCoefficient = 0, gainLinear = 1;
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        double target = 0.0;
        for (std::size_t channel = 0; channel < channels; ++channel) {
            const double sample = input.sample(channel, frame);
            if (detection == EnvelopeFollowerDetection::rms) {
                const double power = sample * sample;
                state->channelPower[channel] = power + rmsCoefficient * (state->channelPower[channel] - power);
                target = std::max(target, std::sqrt(std::max(state->channelPower[channel], 0.0)));
            } else {
                target = std::max(target, std::abs(sample));
            }
        }
        if (const float value = gain.valueAt(frame); value != lastGain) {
            lastGain = value;
            gainLinear = std::pow(10.0, std::clamp(static_cast<double>(value), -24.0, 24.0) / 20.0);
        }
        if (const float value = attack.valueAt(frame); value != lastAttack) {
            lastAttack = value;
            attackCoefficient = smoothing(std::clamp(static_cast<double>(value), minimumAttackMilliseconds, maximumAttackMilliseconds), sampleRate);
        }
        if (const float value = release.valueAt(frame); value != lastRelease) {
            lastRelease = value;
            releaseCoefficient = smoothing(std::clamp(static_cast<double>(value), minimumReleaseMilliseconds, maximumReleaseMilliseconds), sampleRate);
        }
        // Gain applies once, to the detected level; the output is the smoothed level.
        target = std::clamp(target * gainLinear, 0.0, 1.0);
        const double coefficient = target > state->level ? attackCoefficient : releaseCoefficient;
        state->level = target + coefficient * (state->level - target);
        if (!std::isfinite(state->level)) {
            state->level = 0.0;
        }
        state->level = std::clamp(state->level, 0.0, 1.0);
        output[i] = static_cast<float>(state->level);
    }
}

} // namespace bake::dsp
