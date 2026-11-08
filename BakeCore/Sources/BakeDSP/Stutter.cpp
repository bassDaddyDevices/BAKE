#include "BakeDSP/Stutter.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

constexpr double minimumRepeat = 16;

double nextRandom(std::uint32_t& state) noexcept {
    state = state * 1664525u + 1013904223u;
    return static_cast<double>(state >> 8) / 16777216.0;
}

double value(const ParameterSignal& signal, std::size_t frame) noexcept {
    return static_cast<double>(signal.valueAt(frame));
}

/// Folds a pan back into −1…1, so a drifting pan bounces between the speakers.
double reflect(double pan) noexcept {
    const double t = std::fmod(std::fmod(pan + 1, 4) + 4, 4);
    return t <= 2 ? t - 1 : 3 - t;
}

/// Balance law: centre is full level on both sides; panning turns the far side down.
float panGain(double pan, int channel, int channelCount) noexcept {
    if (channelCount != 2) {
        return 1.0f;
    }
    return static_cast<float>(channel == 0 ? std::min(1.0, 1 - pan) : std::min(1.0, 1 + pan));
}

} // namespace

void renderStutter(StutterState* state, const StutterControls& controls, const ControlInput& trigger, int channel,
                   int channelCount, const float* input, std::size_t inputFrames, float* output, std::size_t frameOffset,
                   std::size_t count) noexcept {
    if (state == nullptr || output == nullptr) {
        return;
    }
    const double rate = std::max(controls.sampleRate, 1.0);
    const double ms = rate / 1000;
    const float slew = static_cast<float>(1 / std::max(ms, 1.0));
    const bool timerMoves = controls.every.modulation != nullptr;
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

        // Sets up repeat `n` of the burst here, reading its values now.
        const auto beginRepeat = [&](int n) {
            if (n > 0) {
                state->repeatLength = std::max(state->repeatLength * std::clamp(value(controls.shrink, frame), 0.01, 100.0), minimumRepeat);
                state->level *= static_cast<float>(std::clamp(1 - value(controls.decay, frame), 0.0, 1.0));
            }
            // Drawn for every later repeat, so Jitter 0 and Jitter 20 keep the same chances after.
            const double jitter = n > 0 ? (2 * nextRandom(state->random) - 1) * std::max(value(controls.jitter, frame), 0.0) * ms : 0;
            const double speed = std::exp2(std::clamp(value(controls.pitch, frame) + n * value(controls.pitchDrift, frame), -96.0, 48.0) / 12);
            const int reverse = std::clamp(static_cast<int>(std::lround(value(controls.reverse, frame))), 0, 2);
            const bool reversed = reverse == 2 || (reverse == 1 && n % 2 == 1);
            const double start = state->captureStart + jitter;
            const double pan = reflect(value(controls.pan, frame) + n * value(controls.panDrift, frame));
            state->repeat = n;
            state->repeatStart = now;
            state->gateOpen = std::clamp(value(controls.gate, frame), 0.05, 1.0) * state->repeatLength;
            state->oldVelocity = state->velocity;
            state->velocity = reversed ? -speed : speed;
            const double fade = std::min(std::max(value(controls.smooth, frame), 0.0) * ms, state->repeatLength / 2);
            path.jump(reversed ? start + (state->repeatLength - 1) * speed : start, fade, state->level * panGain(pan, channel, channelCount));
        };

        // The repeat ends: the next one starts, or the burst ends and the input plays again.
        if (state->inBurst && now - state->repeatStart >= state->repeatLength) {
            if (state->repeat + 1 < state->repeats) {
                beginRepeat(state->repeat + 1);
            } else {
                state->inBurst = false;
                state->oldVelocity = state->velocity;
                state->velocity = 1;
                const double fade = std::min(std::max(value(controls.smooth, frame), 0.0) * ms, state->repeatLength / 2);
                path.jump(now, fade, 1.0f);
            }
        }

        // A burst may start here: on a bang while Trigger is wired, else every Every ms.
        bool candidate = false;
        if (trigger.isWired()) {
            const float level = trigger.valueAt(frame);
            candidate = level > 0.5f && state->previousTrigger <= 0.5f;
            state->previousTrigger = level;
        } else {
            const double every = std::max(value(controls.every, frame) * ms, 1.0);
            const double position = timerMoves ? state->timerPosition : now / every;
            const auto index = static_cast<std::int64_t>(std::floor(position));
            candidate = index > state->lastBurst;
            state->lastBurst = std::max(state->lastBurst, index);
            state->timerPosition += 1 / every;
        }
        if (candidate && nextRandom(state->random) < std::clamp(value(controls.chance, frame), 0.0, 1.0)) {
            state->inBurst = true;
            state->repeats = std::clamp(static_cast<int>(std::lround(value(controls.repeats, frame))), 1, 256);
            state->repeatLength = std::max(value(controls.size, frame) * ms, minimumRepeat);
            state->captureStart = now + value(controls.capture, frame) * ms;
            state->level = 1;
            beginRepeat(0);
        }

        // The gate: open for its share of each repeat, slewed so it never clicks.
        const float target = state->inBurst && now - state->repeatStart >= state->gateOpen ? 0.0f : 1.0f;
        state->envelope = target > state->envelope ? std::min(state->envelope + slew, target) : std::max(state->envelope - slew, target);

        const float wet = path.read(input, inputFrames) * state->envelope;
        path.advance(state->velocity, state->oldVelocity);
        const float dry = frame < inputFrames && std::isfinite(input[frame]) ? input[frame] : 0.0f;
        const float mix = std::clamp(controls.mix.valueAt(frame), 0.0f, 1.0f);
        output[i] = mix >= 1 ? wet : dry + (wet - dry) * mix;
    }
}

} // namespace bake::dsp
