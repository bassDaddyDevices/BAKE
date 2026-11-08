#include "BakeDSP/Waveshaper.h"

#include <algorithm>
#include <cmath>

#include "BakeDSP/Oversampling.h"

namespace bake::dsp {
namespace {

constexpr float pi = 3.14159265358979f;

/// The curve at drive input `u`, bounded by ±1 for every curve.
float curveValue(WaveshaperCurve curve, float u) noexcept {
    switch (curve) {
    case WaveshaperCurve::tanh: return std::tanh(u);
    case WaveshaperCurve::arctan: return (2.0f / pi) * std::atan(u * (pi / 2.0f));
    case WaveshaperCurve::softsign: return u / (1.0f + std::fabs(u));
    case WaveshaperCurve::sine: return std::sin(u);
    case WaveshaperCurve::cubic: {
        const float v = std::clamp(u, -1.0f, 1.0f);
        return 1.5f * v - 0.5f * v * v * v;
    }
    case WaveshaperCurve::hardClip: return std::clamp(u, -1.0f, 1.0f);
    case WaveshaperCurve::asymmetric: return u >= 0.0f ? std::tanh(u) : 0.6f * std::tanh(u / 0.6f);
    case WaveshaperCurve::chebyshev: {
        // 1·T1 + 0.5·T3 + 0.25·T5 of the clipped input, scaled to stay within ±1.
        const float v = std::clamp(u, -1.0f, 1.0f);
        const float v2 = v * v;
        const float t3 = v * (4.0f * v2 - 3.0f);
        const float t5 = v * (16.0f * v2 * v2 - 20.0f * v2 + 5.0f);
        return (v + 0.5f * t3 + 0.25f * t5) / 1.75f;
    }
    }
    return 0.0f;
}

/// What the curve reaches at full drive: dividing by it makes ±1 in give ±1 out. Curves that
/// already reach ±1 (or loop, like sine) are left alone.
float curveNormal(WaveshaperCurve curve, float drive) noexcept {
    switch (curve) {
    case WaveshaperCurve::tanh:
    case WaveshaperCurve::arctan:
    case WaveshaperCurve::softsign:
    case WaveshaperCurve::asymmetric:
        return curveValue(curve, drive);
    default:
        return 1.0f;
    }
}

float clampedUnit(float value) noexcept { return std::clamp(value, 0.0f, 1.0f); }

/// Dry + (shaped − dry) · intensity, with the constant at silence removed. Equals the original
/// tanh Waveshaper bit for bit when `curve` is tanh and `bias` is 0.
float wetSample(WaveshaperCurve curve, float source, float amount, float bias) noexcept {
    const float drive = 1.0f + 15.0f * amount;
    const float offset = 2.0f * std::clamp(bias, -1.0f, 1.0f);
    const float shaped = (curveValue(curve, drive * source + offset) - curveValue(curve, offset)) / curveNormal(curve, drive);
    return source + amount * (shaped - source);
}

} // namespace

float waveshaperTransfer(WaveshaperCurve curve, float x, float intensity, float bias) noexcept {
    return wetSample(curve, x, clampedUnit(intensity), bias);
}

void renderWaveshaper(const ParameterSignal& intensity, const ParameterSignal& mix,
                      const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (input == nullptr || output == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float source = std::isfinite(input[i]) ? input[i] : 0.0f;
        const float wet = wetSample(WaveshaperCurve::tanh, source, clampedUnit(intensity.valueAt(frame)), 0.0f);
        output[i] = source + (wet - source) * clampedUnit(mix.valueAt(frame));
    }
}

std::size_t waveshaperScratchFloats(int oversampling, std::size_t maxCount) noexcept {
    return oversamplingScratchFloats(oversampling, maxCount);
}

void renderWaveshaperCurve(WaveshaperCurve curve, int oversampling,
                           const ParameterSignal& intensity, const ParameterSignal& bias, const ParameterSignal& mix,
                           const float* input, std::size_t inputFrames,
                           float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept {
    renderWaveshaperCurve(curve, ParameterSignal(), oversampling, intensity, bias, mix, input, inputFrames, output,
                          frameOffset, count, scratch);
}

void renderWaveshaperCurve(WaveshaperCurve fixedCurve, const ParameterSignal& curveIndex, int oversampling,
                           const ParameterSignal& intensity, const ParameterSignal& bias, const ParameterSignal& mix,
                           const float* input, std::size_t inputFrames,
                           float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept {
    const auto curveAt = [&](std::size_t frame) { return choiceAt(curveIndex, frame, fixedCurve, 8); };
    if (input == nullptr || output == nullptr || scratch == nullptr || count == 0) {
        return;
    }
    const int factor = clampOversampling(oversampling);
    auto dryAt = [&](std::size_t frame) {
        const float value = oversampling::inputAt(input, inputFrames, static_cast<long long>(frame));
        return std::isfinite(value) ? value : 0.0f;
    };
    if (factor == 1) {
        for (std::size_t i = 0; i < count; ++i) {
            const std::size_t frame = frameOffset + i;
            const float source = dryAt(frame);
            const float wet = wetSample(curveAt(frame), source, clampedUnit(intensity.valueAt(frame)), bias.valueAt(frame));
            output[i] = source + (wet - source) * clampedUnit(mix.valueAt(frame));
        }
        return;
    }
    renderOversampled(factor, input, inputFrames, output, frameOffset, count, scratch,
                      [&](float upsampled, std::size_t frame) {
                          const float source = std::isfinite(upsampled) ? upsampled : 0.0f;
                          return wetSample(curveAt(frame), source, clampedUnit(intensity.valueAt(frame)), bias.valueAt(frame));
                      });
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float source = dryAt(frame);
        output[i] = source + (output[i] - source) * clampedUnit(mix.valueAt(frame));
    }
}

} // namespace bake::dsp
