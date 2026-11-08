#include "BakeDSP/StepFX.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

constexpr double minimumSlice = 16;

double nextRandom(std::uint32_t& state) noexcept {
    state = state * 1664525u + 1013904223u;
    return static_cast<double>(state >> 8) / 16777216.0;
}

double value(const ParameterSignal& signal, std::size_t frame) noexcept {
    return static_cast<double>(signal.valueAt(frame));
}

/// Frames from `frame` to the next bang on `clock`, or 0 if there is none.
double framesToNextBang(const ControlInput& clock, std::size_t frame) noexcept {
    float previous = clock.valueAt(frame);
    for (std::size_t next = frame + 1; next < clock.frames; ++next) {
        const float level = clock.valueAt(next);
        if (level > 0.5f && previous <= 0.5f) {
            return static_cast<double>(next - frame);
        }
        previous = level;
    }
    return 0;
}

} // namespace

void renderStepFX(StepFXState* state, const StepFXControls& controls, const ControlInput& clock, const float* input,
                  std::size_t inputFrames, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || output == nullptr) {
        return;
    }
    const double rate = std::max(controls.sampleRate, 1.0);
    const double ms = rate / 1000;
    const float slew = static_cast<float>(1 / std::max(ms, 1.0));
    const int steps = controls.pattern == nullptr ? 0 : std::max(controls.steps, 0);
    const bool timerMoves = controls.tempo.modulation != nullptr || controls.step.modulation != nullptr;
    auto& path = state->path;

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const auto now = static_cast<double>(frame);
        if (!state->started) {
            state->started = true;
            state->random = controls.seed;
            path.position = now;
            path.oldPosition = now;
        }
        const auto smoothFor = [&](double cap) { return std::min(std::max(value(controls.smooth, frame), 0.0) * ms, cap / 2); };

        // A step may start here, and how long it lasts.
        double length = 0;
        if (clock.isWired()) {
            const float level = clock.valueAt(frame);
            if (level > 0.5f && state->previousClock <= 0.5f) {
                length = framesToNextBang(clock, frame);
                if (length <= 0) {
                    length = state->stepLength > 0 ? state->stepLength : std::max(static_cast<double>(inputFrames) - now, 1.0);
                }
            }
            state->previousClock = level;
        } else {
            double quarters = 0.25;
            if (controls.stepQuarters != nullptr && controls.stepCount > 0) {
                const int index = std::clamp(static_cast<int>(std::lround(value(controls.step, frame))), 0, controls.stepCount - 1);
                quarters = controls.stepQuarters[index];
            }
            const double stepFrames = std::max(quarters * 60 / std::clamp(value(controls.tempo, frame), 1.0, 1000.0) * rate, 1.0);
            const double position = timerMoves ? state->timerPosition : now / stepFrames;
            const auto tick = static_cast<std::int64_t>(std::floor(position));
            if (tick > state->lastTick) {
                length = stepFrames;
            }
            state->lastTick = std::max(state->lastTick, tick);
            state->timerPosition += 1 / stepFrames;
        }

        // The step ends with no new one starting here: the input passes again. (Checked after the
        // start, so back-to-back steps make one jump, not two.)
        if (length <= 0 && state->inStep && now >= state->stepStart + state->stepLength) {
            state->inStep = false;
            state->effect = static_cast<int>(StepEffect::pass);
            state->oldVelocity = state->velocity;
            state->velocity = 1;
            path.jump(now, smoothFor(state->stepLength), 1.0f);
        }

        if (length > 0 && steps > 0) {
            const std::int64_t k = ++state->stepNumber;
            // Three draws every step, so no control reshuffles another's choices.
            const double variationRoll = nextRandom(state->random);
            const double effectRoll = nextRandom(state->random);
            const double chanceRoll = nextRandom(state->random);
            const auto rotate = static_cast<std::int64_t>(std::llround(value(controls.rotate, frame)));
            const auto cell = static_cast<int>(((k + rotate) % steps + steps) % steps);
            int effect = std::clamp(controls.pattern[cell], 0, 5);
            if (variationRoll < std::clamp(value(controls.variation, frame), 0.0, 1.0)) {
                effect = std::min(1 + static_cast<int>(effectRoll * 5), 5);
            }
            if (effect != 0 && chanceRoll >= std::clamp(value(controls.chance, frame), 0.0, 1.0)) {
                effect = 0;
            }
            state->inStep = true;
            state->effect = effect;
            state->stepStart = now;
            state->stepLength = length;
            state->oldVelocity = state->velocity;
            double target = now;
            double cap = length;
            state->velocity = 1;
            switch (static_cast<StepEffect>(effect)) {
            case StepEffect::stutter:
                state->sliceLength = std::max(value(controls.stutterSize, frame) * ms, minimumSlice);
                state->sliceStart = now;
                state->sliceRepeatStart = now;
                cap = std::min(length, state->sliceLength);
                break;
            case StepEffect::reverse:
                target = now + length - 1;
                state->velocity = -1;
                break;
            case StepEffect::tapeStop:
                state->curve = std::clamp(value(controls.curve, frame), 0.25, 4.0);
                break;
            case StepEffect::halfTime:
                state->velocity = std::clamp(value(controls.speed, frame), 0.05, 1.0);
                break;
            case StepEffect::gate:
                state->gateOpen = std::clamp(value(controls.gate, frame), 0.05, 1.0) * length;
                break;
            case StepEffect::pass:
                break;
            }
            path.jump(target, smoothFor(cap), 1.0f);
        }

        // Inside the step: Stutter's slices repeat; Tape Stop slows down.
        if (state->inStep) {
            const double age = now - state->stepStart;
            if (state->effect == static_cast<int>(StepEffect::stutter) && now - state->sliceRepeatStart >= state->sliceLength) {
                state->sliceRepeatStart = now;
                state->oldVelocity = state->velocity;
                path.jump(state->sliceStart, smoothFor(state->sliceLength), 1.0f);
            } else if (state->effect == static_cast<int>(StepEffect::tapeStop)) {
                state->velocity = std::pow(std::max(1 - age / state->stepLength, 0.0), state->curve);
            }
        }
        const bool closed = state->inStep && state->effect == static_cast<int>(StepEffect::gate) && now - state->stepStart >= state->gateOpen;
        const float target = closed ? 0.0f : 1.0f;
        state->envelope = target > state->envelope ? std::min(state->envelope + slew, target) : std::max(state->envelope - slew, target);

        const float wet = path.read(input, inputFrames) * state->envelope;
        path.advance(state->velocity, state->oldVelocity);
        const float dry = frame < inputFrames && std::isfinite(input[frame]) ? input[frame] : 0.0f;
        const float mix = std::clamp(controls.mix.valueAt(frame), 0.0f, 1.0f);
        output[i] = mix >= 1 ? wet : dry + (wet - dry) * mix;
    }
}

} // namespace bake::dsp
