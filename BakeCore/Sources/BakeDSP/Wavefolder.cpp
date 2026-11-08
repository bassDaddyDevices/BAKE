#include "BakeDSP/Wavefolder.h"

#include <algorithm>
#include <cmath>

#include "BakeDSP/Oversampling.h"

namespace bake::dsp {
namespace {

constexpr float halfPi = 1.57079632679f;

float foldTriangle(float value) noexcept {
    float phase = std::fmod(value + 1.0f, 4.0f);
    if (phase < 0.0f) {
        phase += 4.0f;
    }
    return phase <= 2.0f ? phase - 1.0f : 3.0f - phase;
}

/// Leaves −1…1 nearly alone (a smooth S) and folds back smoothly beyond it, like a Serge-style folder.
float foldSine(float value) noexcept { return std::sin(halfPi * value); }

float foldOnce(WavefolderShape shape, float value) noexcept {
    return shape == WavefolderShape::sine ? foldSine(value) : foldTriangle(value);
}

float clampedUnit(float value) noexcept { return std::clamp(value, 0.0f, 1.0f); }

/// The wet signal for one sample (before Mix). The triangle shape equals the original Wavefolder.
float wetSample(WavefolderShape shape, float dry, float fold, float symmetry, int stageCount, float saturate) noexcept {
    const float amount = std::clamp(fold, 0.0f, 1.0f);
    const float bias = std::clamp(symmetry, -1.0f, 1.0f) * amount;
    float wet = dry * (1.0f + 15.0f * amount) + bias;
    // A fold leaves −1…1 unchanged, so each extra stage scales by (1 + Fold) before folding again;
    // at Fold 0 every stage is clean.
    for (int stage = 0; stage < stageCount; ++stage) {
        if (stage > 0) {
            wet *= 1.0f + amount;
        }
        wet = foldOnce(shape, wet);
    }
    wet = wet + saturate * (std::tanh(2.0f * wet) - wet);
    return std::clamp(wet, -1.0f, 1.0f);
}

int clampStages(int stages) noexcept { return std::clamp(stages, 1, maxWavefolderStages); }

} // namespace

float wavefolderTransfer(WavefolderShape shape, float x, float fold, float symmetry, int stages, float saturation) noexcept {
    return wetSample(shape, x, fold, symmetry, clampStages(stages), clampedUnit(saturation));
}

void renderWavefolder(const ParameterSignal& fold, const ParameterSignal& symmetry, const ParameterSignal& mix,
                      int stages, float saturation, const float* input, float* output,
                      std::size_t frameOffset, std::size_t count) noexcept {
    if (input == nullptr || output == nullptr) {
        return;
    }
    const int stageCount = clampStages(stages);
    const float saturate = clampedUnit(saturation);
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float dry = std::isfinite(input[i]) ? input[i] : 0.0f;
        const float wet = wetSample(WavefolderShape::triangle, dry, fold.valueAt(frame), symmetry.valueAt(frame), stageCount, saturate);
        const float blend = clampedUnit(mix.valueAt(frame));
        output[i] = dry + (wet - dry) * blend;
    }
}

std::size_t wavefolderScratchFloats(int oversampling, std::size_t maxCount) noexcept {
    return oversamplingScratchFloats(oversampling, maxCount);
}

void renderWavefolderOversampled(WavefolderShape shape, int oversampling,
                                 const ParameterSignal& fold, const ParameterSignal& symmetry, const ParameterSignal& mix,
                                 int stages, float saturation,
                                 const float* input, std::size_t inputFrames,
                                 float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept {
    ParameterSignal fixedSaturation;
    fixedSaturation.base = saturation;
    renderWavefolderOversampled(shape, ParameterSignal(), oversampling, fold, symmetry, mix, stages, fixedSaturation,
                                input, inputFrames, output, frameOffset, count, scratch);
}

void renderWavefolderOversampled(WavefolderShape fixedShape, const ParameterSignal& shapeIndex, int oversampling,
                                 const ParameterSignal& fold, const ParameterSignal& symmetry, const ParameterSignal& mix,
                                 int stages, const ParameterSignal& saturation,
                                 const float* input, std::size_t inputFrames,
                                 float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept {
    if (input == nullptr || output == nullptr || scratch == nullptr || count == 0) {
        return;
    }
    const int factor = clampOversampling(oversampling);
    const int stageCount = clampStages(stages);
    // Both read per sample; unmodulated, the shape is the fixed one and the saturation its knob value.
    const auto shapeAt = [&](std::size_t frame) {
        return shapeIndex.modulation == nullptr ? fixedShape
            : static_cast<WavefolderShape>(std::clamp(static_cast<int>(std::lround(shapeIndex.valueAt(frame))), 0, 1));
    };
    const auto saturateAt = [&](std::size_t frame) { return clampedUnit(saturation.valueAt(frame)); };
    auto dryAt = [&](std::size_t frame) {
        const float value = oversampling::inputAt(input, inputFrames, static_cast<long long>(frame));
        return std::isfinite(value) ? value : 0.0f;
    };
    if (factor == 1) {
        for (std::size_t i = 0; i < count; ++i) {
            const std::size_t frame = frameOffset + i;
            const float dry = dryAt(frame);
            const float wet = wetSample(shapeAt(frame), dry, fold.valueAt(frame), symmetry.valueAt(frame), stageCount, saturateAt(frame));
            output[i] = dry + (wet - dry) * clampedUnit(mix.valueAt(frame));
        }
        return;
    }
    renderOversampled(factor, input, inputFrames, output, frameOffset, count, scratch,
                      [&](float upsampled, std::size_t frame) {
                          const float source = std::isfinite(upsampled) ? upsampled : 0.0f;
                          return wetSample(shapeAt(frame), source, fold.valueAt(frame), symmetry.valueAt(frame), stageCount, saturateAt(frame));
                      });
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float dry = dryAt(frame);
        output[i] = dry + (output[i] - dry) * clampedUnit(mix.valueAt(frame));
    }
}

} // namespace bake::dsp
