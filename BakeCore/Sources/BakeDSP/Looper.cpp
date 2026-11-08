#include "BakeDSP/Looper.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

double value(const ParameterSignal& signal, std::size_t frame) noexcept {
    return static_cast<double>(signal.valueAt(frame));
}

/// The nearest frame within `radius` where the source rises through 0, or `position` if none.
double snapped(const LooperControls& controls, double position) noexcept {
    const float* source = controls.snapSource;
    if (!controls.snap || source == nullptr || controls.snapFrames < 2) {
        return position;
    }
    const auto radius = static_cast<std::ptrdiff_t>(0.005 * controls.sampleRate);
    const auto centre = static_cast<std::ptrdiff_t>(std::lround(position));
    const auto last = static_cast<std::ptrdiff_t>(controls.snapFrames) - 1;
    for (std::ptrdiff_t distance = 0; distance <= radius; ++distance) {
        for (const std::ptrdiff_t frame : {centre - distance, centre + distance}) {
            if (frame >= 1 && frame <= last && source[frame - 1] < 0 && source[frame] >= 0) {
                return static_cast<double>(frame);
            }
        }
    }
    return position;
}

} // namespace

void renderLooper(LooperState* state, const LooperLayout& layout, const LooperControls& controls, const float* input,
                  std::size_t inputFrames, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || output == nullptr) {
        return;
    }
    const int passes = layout.passLengths == nullptr ? 0 : std::max(layout.passCount, 0);
    const double rate = std::max(controls.sampleRate, 1.0);
    auto& path = state->path;

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const auto now = static_cast<double>(frame);
        if (!state->started) {
            state->started = true;
            state->segment = -1;
            state->segmentEnd = std::max(layout.introFrames, 0.0);
            path.position = now;
            path.oldPosition = now;
        }

        // Move into each segment that starts here (a zero-length intro moves straight into pass 0).
        while (state->segment < passes && now >= state->segmentEnd) {
            const int k = ++state->segment;
            double target, length, gain;
            state->oldVelocity = state->velocity;
            if (k < passes) {
                length = static_cast<double>(std::max<std::int64_t>(layout.passLengths[k], 1));
                const int direction = std::clamp(static_cast<int>(std::lround(value(controls.direction, frame))), 0, 2);
                const bool reversed = direction == 1 || (direction == 2 && k % 2 == 1);
                const double speed = std::exp2(std::clamp(value(controls.pitch, frame) + k * value(controls.pitchDrift, frame), -96.0, 48.0) / 12);
                const double start = snapped(controls, layout.regionStart + value(controls.scrub, frame) / 1000 * rate);
                state->gain = k == 0 ? 1.0f : state->gain * static_cast<float>(std::clamp(1 - value(controls.decay, frame), 0.0, 1.0));
                target = reversed ? start + (length - 1) * speed : start;
                state->velocity = reversed ? -speed : speed;
                gain = state->gain;
                state->segmentEnd += length;
            } else {
                // The tail: the input carries on from the region's end.
                length = static_cast<double>(std::max<std::int64_t>(layout.passLengths[passes - 1], 1));
                target = layout.regionStart + layout.regionLength;
                state->velocity = 1;
                gain = 1;
            }
            if (k == 0 && layout.introFrames <= 0) {
                // No intro to fade from: start on the pass.
                path.position = target;
                path.gain = static_cast<float>(gain);
                state->oldVelocity = state->velocity;
            } else {
                const double fade = std::min(std::max(value(controls.crossfade, frame), 0.0) / 1000 * rate, length / 2);
                path.jump(target, fade, static_cast<float>(gain));
            }
        }

        output[i] = path.read(input, inputFrames);
        path.advance(state->velocity, state->oldVelocity);
    }
}

void renderLooperRepeat(LooperState* state, const LooperRepeat& repeat, const LooperControls& controls,
                        const ControlInput& trigger, const float* input, std::size_t inputFrames, float* output,
                        std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || output == nullptr) {
        return;
    }
    const double rate = std::max(controls.sampleRate, 1.0);
    const double ms = rate / 1000;
    constexpr double minimumPass = 16;  // LooperPlan.minimumPass
    const bool timerMoves = repeat.every.modulation != nullptr;
    auto& path = state->path;

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const auto now = static_cast<double>(frame);
        if (!state->started) {
            state->started = true;
            path.position = now;
            path.oldPosition = now;
        }
        const auto fadeFor = [&](double length) {
            return std::min(std::max(value(controls.crossfade, frame), 0.0) * ms, length / 2);
        };

        // Pass `n` of the loop starts here, with the per-pass controls read now.
        const auto beginPass = [&](int n) {
            if (n > 0) {
                state->passLength = std::max(state->passLength * std::clamp(value(repeat.shrink, frame), 0.5, 2.0), minimumPass);
                state->gain *= static_cast<float>(std::clamp(1 - value(controls.decay, frame), 0.0, 1.0));
            }
            const int direction = std::clamp(static_cast<int>(std::lround(value(controls.direction, frame))), 0, 2);
            const bool reversed = direction == 1 || (direction == 2 && n % 2 == 1);
            const double speed = std::exp2(std::clamp(value(controls.pitch, frame) + n * value(controls.pitchDrift, frame), -96.0, 48.0) / 12);
            state->pass = n;
            state->passStart = now;
            state->oldVelocity = state->velocity;
            state->velocity = reversed ? -speed : speed;
            const double start = state->captureStart;
            path.jump(reversed ? start + (state->passLength - 1) * speed : start, fadeFor(state->passLength), state->gain);
        };

        // A pass ends: the next one starts, or the loop ends and the input plays live again.
        if (state->looping && now - state->passStart >= state->passLength) {
            if (state->pass + 1 < state->passCount) {
                beginPass(state->pass + 1);
            } else {
                state->looping = false;
                state->oldVelocity = state->velocity;
                state->velocity = 1;
                path.jump(now, fadeFor(state->passLength), 1.0f);
            }
        }

        // A loop starts on a bang while Trigger is wired, else every Every ms.
        bool bang = false;
        if (trigger.isWired()) {
            const float level = trigger.valueAt(frame);
            bang = level > 0.5f && state->previousTrigger <= 0.5f;
            state->previousTrigger = level;
        } else {
            const double every = std::max(value(repeat.every, frame) * ms, 1.0);
            const double position = timerMoves ? state->timerPosition : now / every;
            const auto index = static_cast<std::int64_t>(std::floor(position));
            bang = index > state->lastBang;
            state->lastBang = std::max(state->lastBang, index);
            state->timerPosition += 1 / every;
        }
        if (bang) {
            state->looping = true;
            state->passCount = std::clamp(static_cast<int>(std::lround(value(repeat.passes, frame))), 1, 256);
            state->passLength = std::max(value(repeat.length, frame) * ms, minimumPass);
            state->captureStart = snapped(controls, now + value(controls.scrub, frame) * ms);
            state->gain = 1;
            beginPass(0);
        }

        output[i] = path.read(input, inputFrames);
        path.advance(state->velocity, state->oldVelocity);
    }
}

} // namespace bake::dsp
