#include "BakeDSP/Envelope.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

constexpr int attackStage = 0;
constexpr int decayStage = 1;
constexpr int sustainStage = 2;
constexpr int releaseStage = 3;
constexpr int finishedStage = 4;

void moveToward(EnvelopeState& state, double target, double seconds, double sampleRate,
                EnvelopeCurve curve) noexcept {
    // Stages last a whole number of samples, counted exactly: summing 1/(duration·rate) per sample
    // drifts (0.4 s isn't exact in binary), so stage ends would land a sample late.
    const double duration = std::clamp(seconds, 0.001, 10.0);
    const double steps = std::max(std::round(duration * sampleRate), 1.0);
    state.phase = std::min(state.phase + 1.0, steps);   // samples into the stage
    const double progress = state.phase / steps;
    const double shaped = curve == EnvelopeCurve::linear
        ? progress
        : progress * progress * (3.0 - 2.0 * progress);
    state.level = state.startLevel + (target - state.startLevel) * shaped;
    if (state.phase >= steps) {
        state.level = target;
        state.startLevel = target;
        state.phase = 0;
        state.stage += 1;
    }
}

} // namespace

void renderEnvelope(EnvelopeState* state, EnvelopeCurve curve, EnvelopeLoop loop, EnvelopeTriggerMode mode,
                    const ParameterSignal& attack, const ParameterSignal& decay,
                    const ParameterSignal& sustain, const ParameterSignal& release,
                    const ParameterSignal& timeScale, const ControlInput& trigger,
                    double sampleRate, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderEnvelope(state, curve, loop, mode, attack, decay, sustain, release, timeScale, trigger, nullptr,
                   sampleRate, output, frameOffset, count);
}

void renderEnvelope(EnvelopeState* state, EnvelopeCurve curve, EnvelopeLoop loop, EnvelopeTriggerMode mode,
                    const ParameterSignal& attack, const ParameterSignal& decay,
                    const ParameterSignal& sustain, const ParameterSignal& release,
                    const ParameterSignal& timeScale, const ControlInput& trigger, const ParameterSignal* every,
                    double sampleRate, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || output == nullptr || !(sampleRate > 0)) {
        return;
    }
    const bool repeats = every != nullptr && !trigger.isWired();
    const bool timerMoves = repeats && every->modulation != nullptr;
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float triggerValue = trigger.valueAt(frame);
        bool timerBang = false;
        if (repeats) {
            const double period = std::max(static_cast<double>(every->valueAt(frame)) * sampleRate / 1000, 1.0);
            const double position = timerMoves ? state->timerPosition : static_cast<double>(frame) / period;
            const auto index = static_cast<std::int64_t>(std::floor(position));
            timerBang = index > state->lastBang;
            state->lastBang = std::max(state->lastBang, index);
            state->timerPosition += 1 / period;
        }
        const bool rising = timerBang || (trigger.isWired() && triggerValue > 0.5f && state->previousTrigger <= 0.5f);
        const bool falling = trigger.isWired() && triggerValue <= 0.5f && state->previousTrigger > 0.5f;
        if (mode == EnvelopeTriggerMode::classic) {
            if (rising) {
                state->stage = attackStage;
                state->phase = 0;
                state->level = 0;
                state->startLevel = 0;
                state->initialized = true;
            } else if (falling && state->stage >= sustainStage) {
                state->stage = releaseStage;
                state->phase = 0;
                state->startLevel = state->level;
            }
        } else if (rising) {
            // Retrigger from wherever the envelope is, so a bang mid-release never jumps.
            state->stage = attackStage;
            state->phase = 0;
            state->startLevel = state->level;
            state->initialized = true;
        } else if (falling && mode == EnvelopeTriggerMode::gate && state->stage < releaseStage) {
            state->stage = releaseStage;
            state->phase = 0;
            state->startLevel = state->level;
        }
        state->previousTrigger = triggerValue;
        if (!state->initialized) {
            state->startLevel = 0;
            state->initialized = true;
            state->stage = trigger.isWired() ? finishedStage : attackStage;
            state->level = 0;
        }
        const double scale = std::clamp(static_cast<double>(timeScale.valueAt(frame)), 0.1, 10.0);
        switch (state->stage) {
        case attackStage:
            moveToward(*state, 1.0, attack.valueAt(frame) * scale, sampleRate, curve);
            break;
        case decayStage:
            moveToward(*state, std::clamp(static_cast<double>(sustain.valueAt(frame)), 0.0, 1.0), decay.valueAt(frame) * scale, sampleRate, curve);
            if (state->stage == sustainStage && loop == EnvelopeLoop::attackDecay && mode != EnvelopeTriggerMode::oneShot
                && trigger.isWired() && triggerValue > 0.5f) {
                state->stage = attackStage;
                state->phase = 0;
                state->startLevel = state->level;
            } else if (state->stage == sustainStage && (!trigger.isWired() || mode == EnvelopeTriggerMode::oneShot)) {
                // Unwired, or One-shot: there is no held gate, so go straight on to release.
                state->stage = releaseStage;
                state->phase = 0;
                state->startLevel = state->level;
            }
            break;
        case sustainStage:
            state->level = std::clamp(static_cast<double>(sustain.valueAt(frame)), 0.0, 1.0);
            break;
        case releaseStage:
            moveToward(*state, 0.0, release.valueAt(frame) * scale, sampleRate, curve);
            break;
        case finishedStage:
            state->level = 0;
            break;
        default:
            state->level = 0;
            state->stage = finishedStage;
            break;
        }
        output[i] = static_cast<float>(std::clamp(state->level, 0.0, 1.0));
    }
}

} // namespace bake::dsp
