#include "BakeDSP/FractalFilter.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace bake::dsp {
namespace {

constexpr float pi = 3.14159265358979323846f;

float fract(float value) noexcept {
    return value - std::floor(value);
}

float cantorSeed(float u) noexcept {
    for (int i = 0; i < 5; ++i) {
        if (std::floor(3.0f * u) == 1.0f) {
            return 0.0f;
        }
        u = fract(3.0f * u);
    }
    return 1.0f;
}

float escapeSeed(float u, bool julia) noexcept {
    float zx = julia ? -1.5f + 3.0f * u : 0.0f;
    float zy = 0.0f;
    const float cx = julia ? -0.8f : -2.0f + 2.5f * u;
    const float cy = julia ? 0.156f : 0.25f;
    for (int n = 0; n < 32; ++n) {
        if (zx * zx + zy * zy > 4.0f) {
            return static_cast<float>(n) * (1.0f / 32.0f);
        }
        const float nextX = zx * zx - zy * zy + cx;
        zy = 2.0f * zx * zy + cy;
        zx = nextX;
    }
    return 1.0f;
}

float kochSeed(float u) noexcept {
    float sum = 0.0f;
    float weight = 1.0f;
    float frequency = 1.0f;
    for (int i = 0; i < 5; ++i) {
        const float triangle = 1.0f - std::fabs(2.0f * fract(frequency * u) - 1.0f);
        sum += weight * triangle;
        weight *= 0.5f;
        frequency *= 3.0f;
    }
    return sum * (16.0f / 31.0f);
}

float patternSeed(float u, FractalMaskPattern pattern) noexcept {
    switch (pattern) {
    case FractalMaskPattern::cantor: return cantorSeed(u);
    case FractalMaskPattern::mandelbrot: return escapeSeed(u, false);
    case FractalMaskPattern::julia: return escapeSeed(u, true);
    case FractalMaskPattern::koch: return kochSeed(u);
    }
    return kochSeed(u);
}

float rawAt(const FractalMaskSettings& settings, float x) noexcept {
    const std::uint32_t iterations = std::clamp(settings.iterations, 1U, 16U);
    const float warp = std::clamp(settings.warp, 0.1f, 10.0f);
    const float center = std::clamp(settings.center, 0.0f, 1.0f);
    const float q = std::clamp(settings.q, 0.1f, 50.0f);
    float mask = 1.0f;
    for (std::uint32_t g = 1; g <= iterations; ++g) {
        const float scale = static_cast<float>(1U << g);
        const float u = fract(std::fabs(x - center) * warp * scale);
        const float seed = patternSeed(u, settings.pattern);
        const float texture = 0.03f + 0.97f * seed;
        const float resonanceBase = std::sin(pi * fract(scale * x));
        const float resonance = 1.0f + 3.0f * std::pow(resonanceBase, 2.0f * q);
        mask *= texture * resonance;
    }
    return std::isfinite(mask) ? mask : 0.0f;
}

std::uint32_t hash(std::uint32_t value) noexcept {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    value ^= value >> 16;
    return value;
}

float phaseUnit(std::uint32_t seed, std::uint32_t index) noexcept {
    return static_cast<float>(hash(seed ^ index) >> 8) * (1.0f / 16'777'216.0f);
}

} // namespace

void fractalMaskRaw(const FractalMaskSettings& settings, const float* positions,
                    std::size_t binCount, float* output) noexcept {
    if (positions == nullptr || output == nullptr) {
        return;
    }
    for (std::size_t bin = 0; bin < binCount; ++bin) {
        output[bin] = rawAt(settings, positions[bin]);
    }
}

void fractalMaskNormalise(float* rawMask, std::size_t binCount) noexcept {
    if (rawMask == nullptr || binCount <= 1) {
        return;
    }
    double weightedPower = 0.0;
    double weightSum = 0.0;
    for (std::size_t bin = 1; bin < binCount; ++bin) {
        const double weight = 1.0 / static_cast<double>(bin);
        const double value = std::isfinite(rawMask[bin]) ? rawMask[bin] : 0.0;
        weightedPower += weight * value * value;
        weightSum += weight;
    }
    const double rms = weightSum > 0.0 ? std::sqrt(weightedPower / weightSum) : 1.0;
    const double inverse = rms > std::numeric_limits<double>::min() ? 1.0 / rms : 1.0;
    constexpr float minimum = 0.0001f;
    constexpr float maximum = 15.8489319f;
    for (std::size_t bin = 0; bin < binCount; ++bin) {
        const double scaled = static_cast<double>(rawMask[bin]) * inverse;
        rawMask[bin] = std::isfinite(scaled)
            ? static_cast<float>(std::clamp(scaled, static_cast<double>(minimum), static_cast<double>(maximum)))
            : minimum;
    }
}

void fractalMaskApply(float* spectrum, const float* mask, std::size_t binCount,
                      int phaseMode, std::uint32_t seed, std::uint32_t frameIndex) noexcept {
    if (spectrum == nullptr || mask == nullptr) {
        return;
    }
    constexpr float twoPi = 6.28318530717958647692f;
    double inputEnergy = 0.0;
    double outputEnergy = 0.0;
    for (std::size_t bin = 0; bin < binCount; ++bin) {
        const float gain = mask[bin];
        const float real = spectrum[2 * bin];
        const float imaginary = spectrum[2 * bin + 1];
        inputEnergy += static_cast<double>(real) * real + static_cast<double>(imaginary) * imaginary;
        if (phaseMode == 2) {
            spectrum[2 * bin] = real * gain;
            spectrum[2 * bin + 1] = -imaginary * gain;
        } else if (phaseMode == 1) {
            const std::uint32_t key = frameIndex * 65'536U + static_cast<std::uint32_t>(bin);
            const float phase = twoPi * phaseUnit(seed, key);
            const float magnitude = std::sqrt(real * real + imaginary * imaginary) * gain;
            spectrum[2 * bin] = magnitude * std::cos(phase);
            spectrum[2 * bin + 1] = magnitude * std::sin(phase);
        } else {
            spectrum[2 * bin] = real * gain;
            spectrum[2 * bin + 1] = imaginary * gain;
        }
        outputEnergy += static_cast<double>(spectrum[2 * bin]) * spectrum[2 * bin]
            + static_cast<double>(spectrum[2 * bin + 1]) * spectrum[2 * bin + 1];
    }
    // The mask reshapes the spectrum but keeps each frame's energy, so the filter keeps the input's
    // loudness whatever the pattern (a deep Cantor mask leaves only a few bins open). The boost is
    // capped at +24 dB; a silent frame stays silent.
    if (outputEnergy > 1e-30 && inputEnergy > 0.0) {
        const float match = static_cast<float>(std::min(std::sqrt(inputEnergy / outputEnergy), 15.8489319));
        for (std::size_t index = 0; index < 2 * binCount; ++index) {
            spectrum[index] *= match;
        }
    }
}

std::size_t fractalFilterMaxRows(const StftLayout& layout, std::size_t maxChunkFrames) noexcept {
    if (!stftLayoutIsValid(layout) || maxChunkFrames == 0) {
        return 0;
    }
    const std::size_t hop = static_cast<std::size_t>(layout.hop);
    return (maxChunkFrames + hop - 1) / hop + stftOverlap(layout) + 1;
}

void fractalFilterProcessChannel(const StftLayout& layout, const double* window,
                                 const float* input, std::size_t signalFrames,
                                 std::size_t sampleStart, std::size_t sampleCount,
                                 std::size_t firstFrame, std::size_t frameCount,
                                 float* rawMasks, const std::uint32_t* phases, std::uint32_t seed,
                                 float* spectrum, float* rows, double* stftScratch,
                                 float* output) noexcept {
    if (!stftLayoutIsValid(layout) || window == nullptr || input == nullptr || rawMasks == nullptr ||
        phases == nullptr || spectrum == nullptr || rows == nullptr || stftScratch == nullptr || output == nullptr ||
        sampleStart > signalFrames || sampleCount > signalFrames - sampleStart) {
        return;
    }
    const StftFrameRange covering = stftFramesCovering(layout, signalFrames, sampleStart, sampleCount);
    if (covering.first != firstFrame || covering.count != frameCount ||
        frameCount == 0 || frameCount > stftFrameCount(layout, signalFrames)) {
        return;
    }
    const std::size_t bins = stftBinCount(layout);
    stftForward(layout, input, signalFrames, firstFrame, frameCount, spectrum, stftScratch);
    for (std::size_t frame = 0; frame < frameCount; ++frame) {
        float* mask = rawMasks + frame * bins;
        fractalMaskNormalise(mask, bins);
        fractalMaskApply(spectrum + frame * bins * 2, mask, bins,
                         static_cast<int>(phases[frame]), seed,
                         static_cast<std::uint32_t>(firstFrame + frame));
    }
    stftInverseRows(layout, spectrum, frameCount, rows, stftScratch);
    stftOverlapAdd(layout, window, rows, firstFrame, frameCount, signalFrames,
                   sampleStart, sampleCount, output);
}

} // namespace bake::dsp
