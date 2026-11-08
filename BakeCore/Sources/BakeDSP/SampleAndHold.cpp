#include "BakeDSP/SampleAndHold.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

void renderSampleAndHold(SampleAndHoldState* state, SampleAndHoldMode mode, const AudioInput& audio,
                         const ControlInput& signal, const ControlInput& trigger, const ParameterSignal& rate,
                         const ParameterSignal& glideMs, double sampleRate, float* output, std::size_t frameOffset,
                         std::size_t count) noexcept {
    if (state == nullptr || output == nullptr || sampleRate <= 0) {
        return;
    }
    const bool triggered = trigger.isWired();
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float source = signal.isWired() ? signal.valueAt(frame) : (audio.isWired() ? audio.sample(0, frame) : 0.0f);
        if (!state->started) {
            state->held = source;
            state->smoothed = source;
            state->started = true;
        }
        bool tracking = false;
        bool take = false;
        if (triggered) {
            const float level = trigger.valueAt(frame);
            take = level > 0.5f && state->previousTrigger <= 0.5f;
            tracking = level > 0.5f;
            state->previousTrigger = level;
        } else {
            tracking = state->phase < 0.5;
            state->phase += std::max(static_cast<double>(rate.valueAt(frame)), 0.0) / sampleRate;
            if (state->phase >= 1.0) {
                state->phase -= std::floor(state->phase);
                take = true;
                tracking = true;
            }
        }
        if (take || (mode == SampleAndHoldMode::trackAndHold && tracking)) {
            state->held = source;
        }
        const float milliseconds = glideMs.valueAt(frame);
        float value = state->held;
        if (milliseconds > 0.0f) {
            const double coefficient = std::exp(-1.0 / (static_cast<double>(milliseconds) * 0.001 * sampleRate));
            state->smoothed = static_cast<float>(coefficient * state->smoothed + (1.0 - coefficient) * state->held);
            value = state->smoothed;
        } else {
            state->smoothed = state->held;
        }
        output[i] = std::isfinite(value) ? value : 0.0f;
    }
}

} // namespace bake::dsp
