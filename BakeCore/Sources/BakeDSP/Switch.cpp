#include "BakeDSP/Switch.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

constexpr double halfPi = 1.5707963267948966;

int nextRandom(std::uint32_t& state) noexcept {
    state = state * 1664525u + 1013904223u;
    return static_cast<int>(state >> 8);
}

int firstStep(SwitchState& state, SwitchOrder order, int outputs, const int* pattern, std::uint32_t seed) noexcept {
    state.direction = 1;
    state.patternIndex = 0;
    state.random = seed;
    switch (order) {
    case SwitchOrder::random: return nextRandom(state.random) % outputs;
    case SwitchOrder::pattern: return pattern[0];
    default: return 0;
    }
}

int nextStep(SwitchState& state, SwitchOrder order, int outputs, const int* pattern, int patternLength) noexcept {
    const int current = state.current;
    switch (order) {
    case SwitchOrder::pingPong:
        if (outputs == 1) {
            return 0;
        }
        if (current + state.direction < 0 || current + state.direction >= outputs) {
            state.direction = -state.direction;
        }
        return current + state.direction;
    case SwitchOrder::random: {
        if (outputs == 1) {
            return 0;
        }
        const int draw = nextRandom(state.random) % (outputs - 1);   // any output but the current one
        return draw >= current ? draw + 1 : draw;
    }
    case SwitchOrder::pattern:
        state.patternIndex = (state.patternIndex + 1) % patternLength;
        return pattern[state.patternIndex];
    default:
        return (current + 1) % outputs;
    }
}

} // namespace

void renderSwitchGains(SwitchState* state, SwitchOrder order, int outputs, const int* pattern, int patternLength,
                       std::uint32_t seed, double fadeFrames, const ControlInput& advance, const ControlInput& reset,
                       float* gains, std::size_t frameOffset, std::size_t count) noexcept {
    renderSwitchGains(state, order, outputs, pattern, patternLength, seed, fadeFrames, ParameterSignal(), 48000,
                      advance, reset, gains, frameOffset, count);
}

void renderSwitchGains(SwitchState* state, SwitchOrder order, int outputs, const int* pattern, int patternLength,
                       std::uint32_t seed, double fadeFrames, const ParameterSignal& crossfadeMs, double sampleRate,
                       const ControlInput& advance, const ControlInput& reset,
                       float* gains, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || gains == nullptr || outputs < 1) {
        return;
    }
    if (order == SwitchOrder::pattern && (pattern == nullptr || patternLength < 1)) {
        order = SwitchOrder::forward;
    }
    const auto clampStep = [outputs](int step) { return std::clamp(step, 0, outputs - 1); };
    const double fixedFade = std::max(fadeFrames, 0.0);
    if (!state->started) {
        state->current = clampStep(firstStep(*state, order, outputs, pattern, seed));
        state->previous = state->current;
        state->fadeDone = fixedFade;
        state->started = true;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float resetValue = reset.valueAt(frame);
        const float advanceValue = advance.valueAt(frame);
        const bool resetBang = reset.isWired() && resetValue > 0.5f && state->previousReset <= 0.5f;
        const bool advanceBang = advance.isWired() && advanceValue > 0.5f && state->previousAdvance <= 0.5f;
        state->previousReset = resetValue;
        state->previousAdvance = advanceValue;

        int target = state->current;
        if (resetBang) {
            target = clampStep(firstStep(*state, order, outputs, pattern, seed));
            state->armed = true;
        } else if (advanceBang) {
            if (state->armed) {
                state->armed = false;   // the first bang plays step 1
            } else {
                target = clampStep(nextStep(*state, order, outputs, pattern, patternLength));
            }
        }
        if (target != state->current) {
            state->previous = state->current;
            state->current = target;
            state->fadeDone = 0;
            if (crossfadeMs.modulation != nullptr) {
                state->fadeLength = std::max(static_cast<double>(crossfadeMs.valueAt(frame)), 0.0) / 1000 * sampleRate;
            }
        }
        const double fade = crossfadeMs.modulation == nullptr ? fixedFade : state->fadeLength;

        float* frameGains = gains + i * static_cast<std::size_t>(outputs);
        std::fill(frameGains, frameGains + outputs, 0.0f);
        if (state->fadeDone >= fade || state->previous == state->current) {
            frameGains[state->current] = 1.0f;
        } else {
            // Equal-power: old and new gains' squares always sum to 1.
            const double t = state->fadeDone / fade;
            frameGains[state->previous] = static_cast<float>(std::cos(t * halfPi));
            frameGains[state->current] = static_cast<float>(std::sin(t * halfPi));
            state->fadeDone += 1;
        }
    }
}

void applySwitchGain(const float* gains, int outputs, int output, const float* source, float* destination,
                     std::size_t count) noexcept {
    if (gains == nullptr || source == nullptr || destination == nullptr || output < 0 || output >= outputs) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const float sample = std::isfinite(source[i]) ? source[i] : 0.0f;
        destination[i] = sample * gains[i * static_cast<std::size_t>(outputs) + output];
    }
}

void mixSwitchInputs(const AudioInput* inputs, std::size_t inputCount, const float* gains, float* const* outputs,
                     std::size_t channels, std::size_t frameOffset, std::size_t count) noexcept {
    if (outputs == nullptr || gains == nullptr || (inputs == nullptr && inputCount > 0)) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float* frameGains = gains + i * inputCount;
        for (std::size_t channel = 0; channel < channels; ++channel) {
            if (outputs[channel] == nullptr) {
                continue;
            }
            float sum = 0.0f;
            for (std::size_t input = 0; input < inputCount; ++input) {
                sum += inputs[input].spread(channel, frame) * frameGains[input];
            }
            outputs[channel][i] = std::isfinite(sum) ? sum : 0.0f;
        }
    }
}

} // namespace bake::dsp
