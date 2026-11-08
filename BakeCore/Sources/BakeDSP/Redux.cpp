#include "BakeDSP/Redux.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace bake::dsp {
namespace {

std::uint32_t hash(std::uint32_t value) noexcept {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    value ^= value >> 16;
    return value;
}

float uniform(std::uint32_t value) noexcept {
    return static_cast<float>(hash(value) >> 8) / 16'777'216.0f;
}

/// Levels per side. Whole bits keep the original rounding exactly; fractional bits keep the fraction.
float levelsFor(float bits, bool fractional) noexcept {
    if (!fractional) {
        return std::ldexp(1.0f, std::clamp(static_cast<int>(std::lround(bits)), 1, 32) - 1);
    }
    const float clamped = std::clamp(bits, 1.0f, 32.0f);
    const float whole = std::round(clamped);
    return clamped == whole ? std::ldexp(1.0f, static_cast<int>(whole) - 1) : std::exp2(clamped - 1.0f);
}

float quantize(float sample, float levels, ReduxDither dither, std::size_t frame, std::size_t channel,
               float* shapeError) noexcept {
    if (!std::isfinite(sample)) {
        sample = 0;
    }
    const float step = 1.0f / levels;
    float noise = 0.0f;
    if (dither != ReduxDither::off) {
        const auto index = static_cast<std::uint32_t>(frame) ^ (static_cast<std::uint32_t>(channel) * 0x9e3779b9U);
        noise = (uniform(index) - uniform(index ^ 0xa511e9b3U)) * step;
    }
    if (dither == ReduxDither::shaped) {
        // The dither goes inside the loop and the error is measured against the value before it, so the
        // dither is shaped with the rounding error: out - in = e0 - 2 e1 + e2, i.e. noise * (1 - z^-1)^2.
        const float target = sample - (2.0f * shapeError[0] - shapeError[1]);
        const float quantized = std::clamp(std::round((target + noise) / step) * step, -1.0f, 1.0f);
        shapeError[1] = shapeError[0];
        shapeError[0] = std::clamp(quantized - target, -2.0f * step, 2.0f * step);
        return quantized;
    }
    sample += noise;
    return std::clamp(std::round(sample / step) * step, -1.0f, 1.0f);
}

/// Bitwise Operator on the integer form of a sample at `bits` resolution. Only the sample's own
/// magnitude bits (`bits` − 1) of the mask apply, so a wide mask never swamps a low bit depth.
float bitwise(float sample, int bits, ReduxBitwiseOp op, int mask) noexcept {
    const int clampedBits = std::clamp(bits, 1, 32);
    const float levels = std::ldexp(1.0f, clampedBits - 1);
    const long value = std::lround(std::clamp(sample, -1.0f, 1.0f) * levels);
    const long applied = static_cast<long>(mask) & ((1L << (clampedBits - 1)) - 1);
    long combined = 0;
    switch (op) {
    case ReduxBitwiseOp::bitAnd: combined = value & applied; break;
    case ReduxBitwiseOp::bitOr: combined = value | applied; break;
    case ReduxBitwiseOp::bitXor: combined = value ^ applied; break;
    }
    const float result = static_cast<float>(combined) / levels;
    return std::isfinite(result) ? std::clamp(result, -1.0f, 1.0f) : 0.0f;
}

/// Four cascaded biquads (48 dB/oct) used by Downsampling. `state` carries each section's memory.
float antiAlias(float sample, float cutoff, double sampleRate, float* z1, float* z2) noexcept {
    constexpr double pi = 3.14159265358979323846;
    const double frequency = std::clamp(static_cast<double>(cutoff), 10.0, sampleRate * 0.45);
    const double k = std::tan(pi * frequency / sampleRate);
    const double norm = 1.0 / (1.0 + 1.4142135623730951 * k + k * k);
    const double b0 = k * k * norm;
    const double b1 = 2.0 * b0;
    const double b2 = b0;
    const double a1 = 2.0 * (k * k - 1.0) * norm;
    const double a2 = (1.0 - 1.4142135623730951 * k + k * k) * norm;
    double value = sample;
    for (int section = 0; section < reduxAntiAliasSections; ++section) {
        const double filtered = b0 * value + z1[section];
        z1[section] = static_cast<float>(b1 * value - a1 * filtered + z2[section]);
        z2[section] = static_cast<float>(b2 * value - a2 * filtered);
        value = filtered;
    }
    return static_cast<float>(value);
}

} // namespace

void renderRedux(ReduxState& state, ReduxAlgorithm algorithm, ReduxMode mode, ReduxDither dither,
                 ReduxBitwiseOp bitwiseOp, int mask,
                 const ParameterSignal& bitDepth, const ParameterSignal& rateDivider, const ParameterSignal& mix,
                 const float* input, float* output, std::size_t frameOffset, std::size_t count,
                 std::size_t channel, double sampleRate) noexcept {
    renderRedux(state, algorithm, mode, dither, bitwiseOp, mask, ReduxModulation(), bitDepth, rateDivider, mix,
                input, output, frameOffset, count, channel, sampleRate);
}

void renderRedux(ReduxState& state, ReduxAlgorithm fixedAlgorithm, ReduxMode mode, ReduxDither dither,
                 ReduxBitwiseOp fixedBitwiseOp, int fixedMask, const ReduxModulation& modulation,
                 const ParameterSignal& bitDepth, const ParameterSignal& rateDivider, const ParameterSignal& mix,
                 const float* input, float* output, std::size_t frameOffset, std::size_t count,
                 std::size_t channel, double sampleRate) noexcept {
    renderRedux(state, fixedAlgorithm, mode, dither, fixedBitwiseOp, fixedMask, modulation, bitDepth, rateDivider, mix,
                input, output, frameOffset, count, channel, sampleRate, ReduxOptions());
}

void renderRedux(ReduxState& state, ReduxAlgorithm fixedAlgorithm, ReduxMode mode, ReduxDither dither,
                 ReduxBitwiseOp fixedBitwiseOp, int fixedMask, const ReduxModulation& modulation,
                 const ParameterSignal& bitDepth, const ParameterSignal& rateDivider, const ParameterSignal& mix,
                 const float* input, float* output, std::size_t frameOffset, std::size_t count,
                 std::size_t channel, double sampleRate, const ReduxOptions& options) noexcept {
    if (input == nullptr || output == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const auto algorithm = modulation.algorithm.modulation == nullptr ? fixedAlgorithm
            : static_cast<ReduxAlgorithm>(std::clamp(static_cast<int>(std::lround(modulation.algorithm.valueAt(frame))), 0, 4));
        const auto bitwiseOp = modulation.bitwiseOp.modulation == nullptr ? fixedBitwiseOp
            : static_cast<ReduxBitwiseOp>(std::clamp(static_cast<int>(std::lround(modulation.bitwiseOp.valueAt(frame))), 0, 2));
        const int mask = modulation.mask.modulation == nullptr ? fixedMask : static_cast<int>(modulation.mask.valueAt(frame));
        const float source = std::isfinite(input[i]) ? input[i] : 0.0f;
        const float bitValue = bitDepth.valueAt(frame);
        const int bits = static_cast<int>(std::lround(bitValue));
        const float levels = levelsFor(bitValue, options.fractionalBits);
        const int interval = std::clamp(static_cast<int>(std::lround(rateDivider.valueAt(frame))), 1, 256);

        // Interpolation needs a hold interval and previous/current samples; Bit Reduction and
        // Bitwise are per-sample, so the hold interval is fixed at 1 for them.
        const bool rateReduced = algorithm == ReduxAlgorithm::classic
            || algorithm == ReduxAlgorithm::downsampling
            || algorithm == ReduxAlgorithm::sampleAndHold;
        const int effectiveInterval = rateReduced ? interval : 1;
        if (!state.initialized) {
            state.previous = source;
            state.current = source;
            state.phase = 0;
            state.interval = effectiveInterval;
            state.initialized = true;
        }
        if (effectiveInterval != state.interval) {
            state.interval = effectiveInterval;
            state.phase %= effectiveInterval;
        }

        float processed;
        switch (algorithm) {
        case ReduxAlgorithm::classic:
            if (state.phase == 0) {
                state.previous = state.current;
                state.current = quantize(source, levels, dither, frame, channel, state.shapeError);
            }
            processed = mode == ReduxMode::sampleAndHold
                ? state.current
                : state.previous + (state.current - state.previous) * (static_cast<float>(state.phase) / state.interval);
            break;

        case ReduxAlgorithm::bitReduction:
            processed = quantize(source, levels, dither, frame, channel, state.shapeError);
            break;

        case ReduxAlgorithm::sampleAndHold:
            if (state.phase == 0) {
                state.current = source;
            }
            processed = state.current;
            break;

        case ReduxAlgorithm::downsampling: {
            // Anti-alias at the new Nyquist before holding/interpolating, so downsampling stays clean.
            const float cutoff = static_cast<float>(sampleRate * 0.5 / effectiveInterval);
            const float filtered = options.antiAliased != nullptr
                ? options.antiAliased[i]
                : antiAlias(source, cutoff, sampleRate, state.lowZ1, state.lowZ2);
            if (state.phase == 0) {
                state.previous = state.current;
                state.current = filtered;
            }
            processed = mode == ReduxMode::sampleAndHold
                ? state.current
                : state.previous + (state.current - state.previous) * (static_cast<float>(state.phase) / state.interval);
            break;
        }

        case ReduxAlgorithm::bitwise:
            processed = bitwise(source, bits, bitwiseOp, mask);
            break;
        }

        const float amount = std::clamp(mix.valueAt(frame), 0.0f, 1.0f);
        output[i] = source + (processed - source) * amount;
        state.phase = (state.phase + 1) % state.interval;
    }
}

} // namespace bake::dsp
