#include "BakeDSP/Generator.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

/// Scales that give each noise colour an RMS of 1 before the Level gain. Measured on 60 s of each stream.
constexpr double whiteScale = 1.7320508075688772;   // uniform ±1 has an RMS of 1/√3
constexpr double violetScale = 1.2247448713915890;  // the difference of two independent whites is √2 times as loud
constexpr double pinkScale = 0.56627;               // the Kellet filter's output has an RMS of about 1.766
constexpr double brownScale = 0.024494;             // sqrt(3 (1 - 0.9999²)): the leaky walk's stationary RMS is its inverse
constexpr double blueScale = 0.95473;               // the difference of that pink stream has an RMS of about 1.047

std::uint64_t mix(std::uint64_t z) noexcept {
    z += 0x9E3779B97F4A7C15ull;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

/// A repeatable number in [0, 1) for (stream, index, lane).
double unit(std::uint64_t stream, std::uint64_t index, std::uint64_t lane) noexcept {
    const std::uint64_t bits = mix(stream ^ mix(index * 4 + lane));
    return static_cast<double>(bits >> 11) * (1.0 / 9007199254740992.0);
}

std::uint64_t streamFor(std::uint32_t seed, int channel) noexcept {
    return mix((static_cast<std::uint64_t>(seed) << 32) ^ static_cast<std::uint64_t>(channel + 1));
}

double white(std::uint64_t stream, std::uint64_t index) noexcept {
    return unit(stream, index, 0) * 2.0 - 1.0;
}

/// Paul Kellet's refined pink filter on white noise; one step.
double pinkStep(GeneratorState& s, double w) noexcept {
    s.pink[0] = 0.99886 * s.pink[0] + w * 0.0555179;
    s.pink[1] = 0.99332 * s.pink[1] + w * 0.0750759;
    s.pink[2] = 0.96900 * s.pink[2] + w * 0.1538520;
    s.pink[3] = 0.86650 * s.pink[3] + w * 0.3104856;
    s.pink[4] = 0.55000 * s.pink[4] + w * 0.5329522;
    s.pink[5] = -0.7616 * s.pink[5] - w * 0.0168980;
    const double out = s.pink[0] + s.pink[1] + s.pink[2] + s.pink[3] + s.pink[4] + s.pink[5] + s.pink[6] + w * 0.5362;
    s.pink[6] = w * 0.115926;
    return out;
}

} // namespace

void renderGenerator(GeneratorState* state, const GeneratorSettings& settings, int channel, const ParameterSignal& levelDb,
                     const ParameterSignal& density, double sampleRate, float* output, std::size_t frameOffset,
                     std::size_t count) noexcept {
    if (state == nullptr || output == nullptr || sampleRate <= 0) {
        return;
    }
    const std::uint64_t stream = streamFor(settings.seed, channel);
    const bool filtered = settings.type == GeneratorType::pink || settings.type == GeneratorType::blue;
    if (!state->started) {
        state->started = true;
        // Let the filters settle on their own stretch of noise so the render doesn't start with a ramp-up.
        if (filtered) {
            for (std::uint64_t k = 0; k < 4096; ++k) {
                state->lastPink = pinkStep(*state, white(stream, 0x4000000000000000ull + k));
            }
        }
        if (settings.type == GeneratorType::brown) {
            for (std::uint64_t k = 0; k < 60000; ++k) {
                state->brown = 0.9999 * state->brown + white(stream, 0x4000000000000000ull + k);
            }
        }
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double gain = std::pow(10.0, static_cast<double>(levelDb.valueAt(frame)) / 20.0);
        double value = 0;
        switch (settings.type) {
        case GeneratorType::white: value = white(stream, frame) * whiteScale; break;
        case GeneratorType::pink: {
            value = pinkStep(*state, white(stream, frame)) * pinkScale;
            break;
        }
        case GeneratorType::brown: {
            state->brown = 0.9999 * state->brown + white(stream, frame);
            value = state->brown * brownScale;
            break;
        }
        case GeneratorType::blue: {
            const double pink = pinkStep(*state, white(stream, frame));
            value = (pink - state->lastPink) * blueScale;
            state->lastPink = pink;
            break;
        }
        case GeneratorType::violet: {
            const double current = white(stream, frame);
            value = (current - state->lastWhite) * violetScale;
            state->lastWhite = current;
            break;
        }
        case GeneratorType::dust:
        case GeneratorType::velvet: {
            const double chance = std::max(static_cast<double>(density.valueAt(frame)), 0.0) / sampleRate;
            if (unit(stream, frame, 1) < chance) {
                value = settings.type == GeneratorType::dust ? unit(stream, frame, 2) * 2.0 - 1.0
                                                              : (unit(stream, frame, 2) < 0.5 ? -1.0 : 1.0);
            }
            break;
        }
        case GeneratorType::impulse: {
            if (state->phase >= 1.0) {
                value = 1.0;
                state->phase -= std::floor(state->phase);
            }
            state->phase += std::max(static_cast<double>(density.valueAt(frame)), 0.0) / sampleRate;
            break;
        }
        case GeneratorType::silence: break;
        }
        const double result = value * gain;
        output[i] = std::isfinite(result) ? static_cast<float>(result) : 0.0f;
    }
}

} // namespace bake::dsp
