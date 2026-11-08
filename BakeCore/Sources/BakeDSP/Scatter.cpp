#include "BakeDSP/Scatter.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr double pi = 3.14159265358979323846;

/// Catmull-Rom between `x[i]` and `x[i + 1]` at `t` (0…1), the ends held.
double cubic(const float* x, std::size_t frames, std::size_t i, double t) noexcept {
    const auto at = [&](std::ptrdiff_t index) {
        return static_cast<double>(x[static_cast<std::size_t>(std::clamp<std::ptrdiff_t>(index, 0, static_cast<std::ptrdiff_t>(frames) - 1))]);
    };
    const auto n = static_cast<std::ptrdiff_t>(i);
    const double p0 = at(n - 1), p1 = at(n), p2 = at(n + 1), p3 = at(n + 2);
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

double fade(std::size_t frame, std::size_t length) noexcept {
    if (length == 0 || frame >= length) return 1.0;
    return 0.5 * (1.0 - std::cos(pi * static_cast<double>(frame) / static_cast<double>(length)));
}

} // namespace

std::size_t scatterGrainFrames(std::size_t clipFrames, double ratio) noexcept {
    if (clipFrames == 0 || !(ratio > 0)) return 0;
    return static_cast<std::size_t>(std::floor(static_cast<double>(clipFrames - 1) / ratio)) + 1;
}

std::size_t scatterPlace(const float* const* clip, std::size_t clipChannels, std::size_t clipFrames,
                         float* left, float* right, std::size_t outputFrames,
                         std::size_t start, double ratio, double pan, double gain, std::size_t fadeFrames) noexcept {
    if (clip == nullptr || left == nullptr || right == nullptr || clipChannels == 0) return 0;
    const std::size_t length = scatterGrainFrames(clipFrames, ratio);
    if (length == 0 || start >= outputFrames) return length;
    const std::size_t fadeLength = std::min(fadeFrames, length / 2);
    const double where = std::clamp(pan, -1.0, 1.0);
    double leftGain, rightGain;
    if (clipChannels == 1) {
        const double angle = (where + 1.0) * pi / 4.0;
        leftGain = std::cos(angle);
        rightGain = std::sin(angle);
    } else {
        leftGain = where > 0 ? std::cos(where * pi / 2.0) : 1.0;
        rightGain = where < 0 ? std::cos(-where * pi / 2.0) : 1.0;
    }
    const float* first = clip[0];
    const float* second = clipChannels > 1 ? clip[1] : clip[0];
    const std::size_t end = std::min(outputFrames, start + length);
    for (std::size_t frame = start; frame < end; ++frame) {
        const std::size_t i = frame - start;
        const double position = static_cast<double>(i) * ratio;
        const auto index = static_cast<std::size_t>(position);
        const double t = position - static_cast<double>(index);
        const double shape = gain * fade(i, fadeLength) * fade(length - 1 - i, fadeLength);
        left[frame] += static_cast<float>(cubic(first, clipFrames, index, t) * shape * leftGain);
        right[frame] += static_cast<float>(cubic(second, clipFrames, index, t) * shape * rightGain);
    }
    return length;
}

} // namespace bake::dsp
