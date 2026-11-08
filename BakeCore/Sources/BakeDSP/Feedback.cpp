#include "BakeDSP/Feedback.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

float finiteOrZero(float value) noexcept {
    return std::isfinite(value) ? value : 0.0f;
}

double finiteCutoff(const ParameterSignal& signal, std::size_t frame, double sampleRate) noexcept {
    const double value = signal.valueAt(frame);
    const double maximum = std::max(sampleRate * 0.49, 1.0);
    return std::isfinite(value) ? std::clamp(value, 1.0, maximum) : 1.0;
}

} // namespace

void renderFeedback(FeedbackState* state, const AudioInput& input, const AudioInput& returned,
                    int channel, FeedbackMode fixedMode, const ParameterSignal& gain, const ParameterSignal& drive,
                    const ParameterSignal& modeIndex, const ParameterSignal& lowCut,
                    const ParameterSignal& highCut, double sampleRate, int delayFrames,
                    float* output, int frameOffset, int count) noexcept {
    if (state == nullptr || output == nullptr || !(sampleRate > 0.0) || !std::isfinite(sampleRate)) {
        return;
    }

    const std::size_t delay = static_cast<std::size_t>(std::max(delayFrames, 1));
    const double rate = sampleRate;
    for (std::size_t i = 0; i < static_cast<std::size_t>(std::max(count, 0)); ++i) {
        const std::size_t frame = static_cast<std::size_t>(std::max(frameOffset, 0)) + i;
        const float dry = input.spread(channel, frame);
        const float rawReturn = frame >= delay ? returned.spread(channel, frame - delay) : 0.0f;
        const double returnSample = finiteOrZero(rawReturn);
        const double lowFrequency = finiteCutoff(lowCut, frame, rate);
        const double highFrequency = finiteCutoff(highCut, frame, rate);
        double damped = returnSample;
        if (lowFrequency > 20.0 || highFrequency < 20'000.0) {
            const double lowpassFrequency = std::clamp(highFrequency, lowFrequency, std::max(rate * 0.49, lowFrequency));
            const double highpassPole = std::exp(-2.0 * pi * lowFrequency / rate);
            const double lowpassPole = std::exp(-2.0 * pi * lowpassFrequency / rate);
            const double highpassed = highpassPole * (state->highpassOutput + returnSample - state->highpassInput);
            state->highpassInput = returnSample;
            state->highpassOutput = std::isfinite(highpassed) ? highpassed : 0.0;
            const double lowpassed = (1.0 - lowpassPole) * state->highpassOutput + lowpassPole * state->lowpassOutput;
            state->lowpassOutput = std::isfinite(lowpassed) ? lowpassed : 0.0;
            damped = state->lowpassOutput;
        } else {
            state->highpassInput = returnSample;
            state->highpassOutput = returnSample;
            state->lowpassOutput = returnSample;
        }

        const double feedbackGainDb = std::clamp(static_cast<double>(gain.valueAt(frame)), -60.0, 6.0);
        const double driveDb = std::clamp(static_cast<double>(drive.valueAt(frame)), 0.0, 24.0);
        const double feedbackGain = std::pow(10.0, feedbackGainDb / 20.0);
        const double driveGain = std::pow(10.0, driveDb / 20.0);
        const FeedbackMode mode = choiceAt(modeIndex, frame, fixedMode, 4);
        // Always saturated, Drive 0 included: the bound (at most 1 / driveGain) is what keeps a loop
        // with Feedback above 0 dB from growing without limit.
        const double saturated = [&] {
            const double driven = driveGain * feedbackGain * damped;
            switch (mode) {
            case FeedbackMode::tanh:
                return std::tanh(driven) / driveGain;
            case FeedbackMode::tape:
                return (driven / (1.0 + std::abs(driven))) / driveGain;
            case FeedbackMode::hard:
                return std::clamp(driven, -1.0, 1.0) / driveGain;
            case FeedbackMode::crush:
                return std::round(127.0 * std::tanh(driven)) / (127.0 * driveGain);
            }
            return 0.0;
        }();
        const double result = static_cast<double>(dry) + saturated;
        output[i] = std::isfinite(result) ? static_cast<float>(result) : finiteOrZero(dry);
    }
}

} // namespace bake::dsp
