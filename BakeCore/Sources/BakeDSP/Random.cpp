#include "BakeDSP/Random.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

/// splitmix64's finalizer.
std::uint64_t mix(std::uint64_t z) noexcept {
    z += 0x9E3779B97F4A7C15ull;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

/// A repeatable number in [0, 1) for (seed, index, lane): no state, so any step can be drawn in any order.
double unit(std::uint32_t seed, std::uint64_t index, std::uint64_t lane) noexcept {
    const std::uint64_t bits = mix((static_cast<std::uint64_t>(seed) << 32) ^ mix(index * 4 + lane));
    return static_cast<double>(bits >> 11) * (1.0 / 9007199254740992.0);
}

float clamp01(double value) noexcept {
    return static_cast<float>(std::clamp(value, 0.0, 1.0));
}

/// Step `index` of a `random`-mode stream, 0…1.
float drawValue(const RandomSettings& settings, std::uint64_t index) noexcept {
    switch (settings.distribution) {
    case RandomDistribution::uniform: return clamp01(unit(settings.seed, index, 0));
    case RandomDistribution::gaussian: {
        const double radius = std::sqrt(-2.0 * std::log(std::max(unit(settings.seed, index, 0), 1e-12)));
        return clamp01(0.5 + 0.15 * radius * std::cos(2.0 * pi * unit(settings.seed, index, 1)));
    }
    case RandomDistribution::coin: return unit(settings.seed, index, 0) < 0.5 ? 0.0f : 1.0f;
    }
    return 0;
}

float reflect(double value) noexcept {
    for (int guard = 0; guard < 8 && (value < 0.0 || value > 1.0); ++guard) {
        value = value < 0.0 ? -value : 2.0 - value;
    }
    return clamp01(value);
}

/// The next step value in order: a draw, or one more move of the walk.
float nextValue(RandomState& state, const RandomSettings& settings) noexcept {
    const std::uint64_t index = state.generated++;
    if (settings.mode == RandomMode::walk) {
        const double move = (unit(settings.seed, index, 0) * 2.0 - 1.0) * static_cast<double>(settings.stepSize);
        state.walkValue = reflect(static_cast<double>(state.walkValue) + move);
        return state.walkValue;
    }
    return drawValue(settings, index);
}

void begin(RandomState& state, const RandomSettings& settings) noexcept {
    const float first = nextValue(state, settings);
    const float second = nextValue(state, settings);
    const float third = nextValue(state, settings);
    state.window[0] = first;   // step -1 repeats step 0
    state.window[1] = first;
    state.window[2] = second;
    state.window[3] = third;
    state.current = first;
    state.from = first;
    state.started = true;
}

void advance(RandomState& state, const RandomSettings& settings) noexcept {
    state.window[0] = state.window[1];
    state.window[1] = state.window[2];
    state.window[2] = state.window[3];
    state.window[3] = nextValue(state, settings);
}

/// The curve over one step or glide, 0…1 to 0…1.
float shape(RandomInterpolation interpolation, float fraction) noexcept {
    return interpolation == RandomInterpolation::linear ? fraction
                                                         : 0.5f - 0.5f * static_cast<float>(std::cos(pi * fraction));
}

/// The value `fraction` of the way from step n to n + 1.
float between(const RandomState& state, RandomInterpolation interpolation, float fraction) noexcept {
    const float* w = state.window;
    switch (interpolation) {
    case RandomInterpolation::stepped: return w[1];
    case RandomInterpolation::linear:
    case RandomInterpolation::cosine: return w[1] + (w[2] - w[1]) * shape(interpolation, fraction);
    case RandomInterpolation::cubic: {
        // Catmull-Rom through the four values.
        const float t = fraction, t2 = t * t, t3 = t2 * t;
        const float value = 0.5f * ((2.0f * w[1]) + (-w[0] + w[2]) * t + (2.0f * w[0] - 5.0f * w[1] + 4.0f * w[2] - w[3]) * t2 +
                                    (-w[0] + 3.0f * w[1] - 3.0f * w[2] + w[3]) * t3);
        return std::clamp(value, 0.0f, 1.0f);
    }
    }
    return w[1];
}

} // namespace

void renderRandom(RandomState* state, const RandomSettings& settings, const ParameterSignal& rate,
                  const ParameterSignal& minimum, const ParameterSignal& maximum, const ParameterSignal& smoothMs,
                  const ControlInput& trigger, double sampleRate, float* output, std::size_t frameOffset,
                  std::size_t count) noexcept {
    if (state == nullptr || output == nullptr || sampleRate <= 0) {
        return;
    }
    if (!state->started) {
        begin(*state, settings);
    }
    const bool triggered = trigger.isWired();
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        float draw;
        if (triggered) {
            const float level = trigger.valueAt(frame);
            if (level > 0.5f && state->previousTrigger <= 0.5f) {
                state->from = state->current;
                state->lastBang = static_cast<long long>(frame);
                if (state->armed) {
                    state->armed = false;
                } else {
                    advance(*state, settings);
                }
            }
            state->previousTrigger = level;
            const float target = state->window[1];
            if (settings.interpolation == RandomInterpolation::stepped || settings.glideFrames <= 0 || state->lastBang < 0) {
                draw = target;
            } else {
                const double elapsed = static_cast<double>(static_cast<long long>(frame) - state->lastBang);
                draw = elapsed >= settings.glideFrames
                    ? target   // arrived: exactly the step's value, not a rounded blend
                    : state->from + (target - state->from) * shape(settings.interpolation, static_cast<float>(elapsed / settings.glideFrames));
            }
        } else {
            draw = between(*state, settings.interpolation, static_cast<float>(state->phase));
            state->phase += std::max(static_cast<double>(rate.valueAt(frame)), 0.0) / sampleRate;
            for (int guard = 0; state->phase >= 1.0 && guard < 64; ++guard) {
                state->phase -= 1.0;
                advance(*state, settings);
            }
            state->phase = std::min(state->phase, 1.0 - 1e-12);
        }
        state->current = draw;
        const float low = minimum.valueAt(frame);
        const float high = maximum.valueAt(frame);
        const float raw = low + draw * (high - low);
        const float milliseconds = smoothMs.valueAt(frame);
        float value = raw;
        if (milliseconds > 0.0f) {
            const double coefficient = std::exp(-1.0 / (static_cast<double>(milliseconds) * 0.001 * sampleRate));
            state->smoothed = static_cast<float>(coefficient * state->smoothed + (1.0 - coefficient) * raw);
            value = state->smoothed;
        } else {
            state->smoothed = raw;
        }
        output[i] = std::isfinite(value) ? value : 0.0f;
    }
}

} // namespace bake::dsp
