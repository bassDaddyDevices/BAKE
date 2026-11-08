#include "BakeDSP/LFO.h"

#include <cmath>

namespace bake::dsp {
namespace {

constexpr double twoPi = 6.283185307179586;

/// Deterministic sample & hold values in −1…+1 (LCG).
float nextRandom(std::uint32_t& state) noexcept {
    state = state * 1664525u + 1013904223u;
    return static_cast<float>(state >> 8) / 16777216.0f * 2.0f - 1.0f;
}

/// Every shape starts at 0 (square at +1) and rises, like sine.
float shapeValue(LFOShape shape, double phase, float held) noexcept {
    switch (shape) {
    case LFOShape::sine: return static_cast<float>(std::sin(twoPi * phase));
    case LFOShape::triangle:
        return static_cast<float>(phase < 0.25 ? 4 * phase : (phase < 0.75 ? 2 - 4 * phase : 4 * phase - 4));
    case LFOShape::saw: return static_cast<float>(phase < 0.5 ? 2 * phase : 2 * phase - 2);
    case LFOShape::square: return phase < 0.5 ? 1.0f : -1.0f;
    case LFOShape::sampleAndHold: return held;
    }
    return 0;
}

} // namespace

void renderLFO(LFOState* state, LFOShape shape, const ParameterSignal& rate, const ParameterSignal& depth,
               const ControlInput& reset, double sampleRate, float* output, std::size_t frameOffset,
               std::size_t count) noexcept {
    renderLFO(state, shape, rate, depth, ParameterSignal(), reset, sampleRate, output, frameOffset, count);
}

void renderLFO(LFOState* state, LFOShape shape, const ParameterSignal& rate, const ParameterSignal& depth,
               const ParameterSignal& phaseDegrees, const ControlInput& reset, double sampleRate, float* output,
               std::size_t frameOffset, std::size_t count) noexcept {
    renderLFO(state, shape, ParameterSignal(), rate, depth, phaseDegrees, reset, sampleRate, output, frameOffset, count);
}

void renderLFO(LFOState* state, LFOShape fixedShape, const ParameterSignal& shapeIndex, const ParameterSignal& rate,
               const ParameterSignal& depth, const ParameterSignal& phaseDegrees, const ControlInput& reset,
               double sampleRate, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || output == nullptr) {
        return;
    }
    if (!state->started) {
        state->held = nextRandom(state->random);
        state->started = true;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        if (reset.isWired()) {
            const float resetValue = reset.valueAt(frame);
            if (resetValue > 0.5f && state->previousReset <= 0.5f) {
                bool restart = true;
                if (state->clockSync) {
                    const auto now = static_cast<long long>(frame);
                    if (state->lastBang >= 0) {
                        state->interval = static_cast<double>(now - state->lastBang);
                    }
                    state->lastBang = now;
                    // Under one cycle per bang, restart only every 2nd or 4th bang so the cycle completes.
                    const long long every = state->cyclesPerBang < 1 ? std::llround(1.0 / state->cyclesPerBang) : 1;
                    restart = state->bangCount % every == 0;
                    state->bangCount += 1;
                }
                if (restart) {
                    state->phase = state->resetPhase;
                    state->held = nextRandom(state->random);
                }
            }
            state->previousReset = resetValue;
        }
        double phase = state->phase;
        if (phaseDegrees.modulation != nullptr) {
            phase += (static_cast<double>(phaseDegrees.valueAt(frame)) - phaseDegrees.base) / 360.0;
            phase -= std::floor(phase);
        }
        output[i] = shapeValue(choiceAt(shapeIndex, frame, fixedShape, 5), phase, state->held) * depth.valueAt(frame);
        const bool locked = state->clockSync && state->interval > 0;
        state->phase += locked ? state->cyclesPerBang / state->interval : rate.valueAt(frame) / sampleRate;
        if (state->phase >= 1.0) {
            state->phase -= std::floor(state->phase);
            state->held = nextRandom(state->random);
        }
    }
}

} // namespace bake::dsp
