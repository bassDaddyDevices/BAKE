#include "BakeDSP/SingleCycle.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr double pi = 3.14159265358979323846264338327950288;

float finiteOr(float value, float fallback) noexcept {
    return std::isfinite(value) ? value : fallback;
}

double unitHash(std::uint64_t seed, std::uint64_t index) noexcept {
    std::uint64_t z = seed * 0x9E3779B97F4A7C15ull + index;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return static_cast<double>(z >> 11) * (1.0 / 9007199254740992.0);
}

double fract(double value) noexcept {
    return value - std::floor(value);
}

SingleCycleShape shapeAt(const ParameterSignal& signal, std::size_t frame, SingleCycleShape fixed) noexcept {
    return choiceAt(signal, frame, fixed, 7);
}

float generate(SingleCycleShape shape, double t, double width, const float* partials,
               std::size_t partialCount, std::uint64_t seed, std::uint64_t absoluteSample) noexcept {
    switch (shape) {
    case SingleCycleShape::sine:
        return static_cast<float>(std::sin(2.0 * pi * t));
    case SingleCycleShape::triangle: {
        const double shifted = fract(t + 0.25);
        return static_cast<float>(1.0 - 4.0 * std::fabs(shifted - 0.5));
    }
    case SingleCycleShape::saw:
        return static_cast<float>(2.0 * t - 1.0);
    case SingleCycleShape::square:
        return t < 0.5 ? 1.0f : -1.0f;
    case SingleCycleShape::pulse:
        return t < width ? 1.0f : -1.0f;
    case SingleCycleShape::noise:
        return static_cast<float>(2.0 * unitHash(seed, absoluteSample) - 1.0);
    case SingleCycleShape::additive: {
        if (partials == nullptr || partialCount == 0) {
            return 0.0f;
        }
        double sum = 0.0;
        double absoluteSum = 0.0;
        for (std::size_t h = 0; h < partialCount; ++h) {
            const double amplitude = std::isfinite(partials[h]) ? partials[h] : 0.0;
            sum += amplitude * std::sin(2.0 * pi * static_cast<double>(h + 1) * t);
            absoluteSum += std::fabs(amplitude);
        }
        return static_cast<float>(sum / std::max(1.0, absoluteSum));
    }
    }
    return 0.0f;
}

/// One sample at cycle position `t` (0..<1): warped, shaped, then morphed towards a sine of the
/// unwarped `t`.
float sampleAt(SingleCycleShape shape, double t, double pulseWidth, double warpAmount, double morphAmount,
               const float* partials, std::size_t partialCount, std::uint64_t seed, std::uint64_t absoluteSample) noexcept {
    double warped = t;
    if (warpAmount >= 0.0) {
        warped = std::pow(t, 1.0 + 3.0 * warpAmount);
    } else {
        warped = 1.0 - std::pow(1.0 - t, 1.0 + 3.0 * std::fabs(warpAmount));
    }
    const float shaped = generate(shape, warped, pulseWidth, partials, partialCount, seed, absoluteSample);
    const float sine = static_cast<float>(std::sin(2.0 * pi * t));
    const float result = static_cast<float>((1.0 - morphAmount) * shaped + morphAmount * sine);
    return std::isfinite(result) ? result : 0.0f;
}

} // namespace

void renderSingleCycle(SingleCycleShape fixedShape, const ParameterSignal& shapeIndex, const ParameterSignal& width,
                       const ParameterSignal& phase, const ParameterSignal& warp, const ParameterSignal& morph,
                       const float* partials, std::size_t partialCount, std::uint64_t seed,
                       float* output, std::size_t frameSize, std::size_t frameOffset, std::size_t count) noexcept {
    renderSingleCycle(fixedShape, shapeIndex, width, phase, warp, morph, ParameterSignal(), partials, partialCount, seed,
                      output, frameSize, frameOffset, count);
}

void renderSingleCycle(SingleCycleShape fixedShape, const ParameterSignal& shapeIndex, const ParameterSignal& width,
                       const ParameterSignal& phase, const ParameterSignal& warp, const ParameterSignal& morph,
                       const ParameterSignal& harmonic, const float* partials, std::size_t partialCount, std::uint64_t seed,
                       float* output, std::size_t frameSize, std::size_t frameOffset, std::size_t count) noexcept {
    if (output == nullptr || frameSize == 0) {
        return;
    }
    const std::size_t end = frameOffset + count;
    const std::size_t firstCycle = frameOffset / frameSize;
    const std::size_t lastCycle = (end - (end > frameOffset ? 1 : 0)) / frameSize;
    for (std::size_t cycle = firstCycle; cycle <= lastCycle && cycle * frameSize < end; ++cycle) {
        const std::size_t cycleStart = cycle * frameSize;
        const SingleCycleShape shape = shapeAt(shapeIndex, cycleStart, fixedShape);
        const double pulseWidth = std::clamp(static_cast<double>(finiteOr(width.valueAt(cycleStart), 0.5f)), 0.01, 0.99);
        const double phaseTurns = finiteOr(phase.valueAt(cycleStart), 0.0f) / 360.0;
        const double warpAmount = std::clamp(static_cast<double>(finiteOr(warp.valueAt(cycleStart), 0.0f)), -1.0, 1.0);
        const double morphAmount = std::clamp(static_cast<double>(finiteOr(morph.valueAt(cycleStart), 0.0f)), 0.0, 1.0);
        // Whole cycles per frame (an unwired signal reads 0, which means 1).
        const double cycles = static_cast<double>(std::clamp(std::lround(finiteOr(harmonic.valueAt(cycleStart), 1.0f)), 1L, 64L));
        const std::size_t begin = std::max(frameOffset, cycleStart);
        const std::size_t finish = std::min(end, cycleStart + frameSize);
        for (std::size_t absoluteFrame = begin; absoluteFrame < finish; ++absoluteFrame) {
            const std::size_t sample = absoluteFrame - cycleStart;
            const double t = fract(static_cast<double>(sample) * cycles / static_cast<double>(frameSize) + phaseTurns);
            output[absoluteFrame - frameOffset] =
                sampleAt(shape, t, pulseWidth, warpAmount, morphAmount, partials, partialCount, seed, absoluteFrame);
        }
    }
}

void renderSingleCycleOscillator(SingleCycleOscillatorState* state, SingleCycleShape fixedShape,
                                 const ParameterSignal& shapeIndex, const ParameterSignal& width,
                                 const ParameterSignal& phase, const ParameterSignal& warp, const ParameterSignal& morph,
                                 const ParameterSignal& frequency, const float* partials, std::size_t partialCount,
                                 std::uint64_t seed, double sampleRate, float* output, std::size_t frameOffset,
                                 std::size_t count) noexcept {
    if (state == nullptr || output == nullptr || sampleRate <= 0) {
        return;
    }
    for (std::size_t index = 0; index < count; ++index) {
        const std::size_t frame = frameOffset + index;
        const SingleCycleShape shape = shapeAt(shapeIndex, frame, fixedShape);
        const double pulseWidth = std::clamp(static_cast<double>(finiteOr(width.valueAt(frame), 0.5f)), 0.01, 0.99);
        const double phaseTurns = finiteOr(phase.valueAt(frame), 0.0f) / 360.0;
        const double warpAmount = std::clamp(static_cast<double>(finiteOr(warp.valueAt(frame), 0.0f)), -1.0, 1.0);
        const double morphAmount = std::clamp(static_cast<double>(finiteOr(morph.valueAt(frame), 0.0f)), 0.0, 1.0);
        const double t = fract(state->phase + phaseTurns);
        output[index] = sampleAt(shape, t, pulseWidth, warpAmount, morphAmount, partials, partialCount, seed, frame);
        const double hertz = std::clamp(static_cast<double>(finiteOr(frequency.valueAt(frame), 110.0f)), 0.0, sampleRate * 0.5);
        state->phase = fract(state->phase + hertz / sampleRate);
    }
}

} // namespace bake::dsp
