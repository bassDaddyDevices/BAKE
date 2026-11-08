#include "BakeDSP/Matrix.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

std::uint64_t mix(std::uint64_t value) noexcept {
    std::uint64_t x = value + 0x9E3779B97F4A7C15ull;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
    return x ^ (x >> 31);
}

/// One frame of the sum, before scaling.
double layered(const AudioInput* inputs, const ParameterSignal* levelsDb, const std::size_t* offsets,
               std::size_t count, std::size_t channel, std::size_t frame) noexcept {
    double sum = 0.0;
    for (std::size_t k = 0; k < count; ++k) {
        if (!inputs[k].isWired() || frame < offsets[k]) continue;
        const float sample = inputs[k].spread(channel, frame - offsets[k]);
        if (sample == 0.0f) continue;
        sum += static_cast<double>(sample) * std::pow(10.0, static_cast<double>(levelsDb[k].valueAt(frame)) / 20.0);
    }
    return sum;
}

} // namespace

std::size_t matrixPeakFrame(const AudioInput& input) noexcept {
    std::size_t best = 0;
    float level = 0.0f;
    for (std::size_t frame = 0; frame < input.frames; ++frame) {
        for (std::size_t channel = 0; channel < input.channelCount; ++channel) {
            const float value = std::fabs(input.sample(channel, frame));
            if (value > level) {
                level = value;
                best = frame;
            }
        }
    }
    return best;
}

void matrixOffsets(const AudioInput* inputs, std::size_t count, MatrixAlign align, std::size_t range,
                   std::uint64_t seed, std::uint64_t combination, std::size_t* offsets) noexcept {
    for (std::size_t k = 0; k < count; ++k) offsets[k] = 0;
    if (align == MatrixAlign::random) {
        for (std::size_t k = 0; k < count; ++k) {
            if (!inputs[k].isWired()) continue;
            const std::uint64_t h = mix((seed << 40) ^ (combination << 4) ^ static_cast<std::uint64_t>(k));
            offsets[k] = static_cast<std::size_t>(h % (static_cast<std::uint64_t>(range) + 1));
        }
    } else if (align == MatrixAlign::peak) {
        std::size_t peaks[8] = {};
        std::size_t latest = 0;
        for (std::size_t k = 0; k < count && k < 8; ++k) {
            if (!inputs[k].isWired()) continue;
            peaks[k] = matrixPeakFrame(inputs[k]);
            latest = std::max(latest, peaks[k]);
        }
        for (std::size_t k = 0; k < count && k < 8; ++k) {
            if (inputs[k].isWired()) offsets[k] = std::min(latest - peaks[k], range);
        }
    }
}

double matrixPeak(const AudioInput* inputs, const ParameterSignal* levelsDb, const std::size_t* offsets,
                  std::size_t count, std::size_t channels, std::size_t frames) noexcept {
    double peak = 0.0;
    for (std::size_t frame = 0; frame < frames; ++frame) {
        for (std::size_t channel = 0; channel < channels; ++channel) {
            const double value = std::fabs(layered(inputs, levelsDb, offsets, count, channel, frame));
            if (std::isfinite(value)) peak = std::max(peak, value);
        }
    }
    return peak;
}

void matrixRender(const AudioInput* inputs, const ParameterSignal* levelsDb, const std::size_t* offsets,
                  std::size_t count, double scale, float* const* outputs, std::size_t channels,
                  std::size_t first, std::size_t frameCount) noexcept {
    if (outputs == nullptr) return;
    for (std::size_t i = 0; i < frameCount; ++i) {
        for (std::size_t channel = 0; channel < channels; ++channel) {
            if (outputs[channel] == nullptr) continue;
            const double value = layered(inputs, levelsDb, offsets, count, channel, first + i) * scale;
            outputs[channel][i] = std::isfinite(value) ? static_cast<float>(value) : 0.0f;
        }
    }
}

} // namespace bake::dsp
