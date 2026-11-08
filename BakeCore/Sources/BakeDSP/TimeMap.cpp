#include "BakeDSP/TimeMap.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

constexpr double halfPi = 1.5707963267948966;
constexpr double twoPi = 6.283185307179586;

/// A whole-frame read: outside the input, or non-finite, reads 0.
float sampleAt(const float* input, std::size_t frames, std::ptrdiff_t frame) noexcept {
    if (frame < 0 || static_cast<std::size_t>(frame) >= frames) {
        return 0.0f;
    }
    const float value = input[frame];
    return std::isfinite(value) ? value : 0.0f;
}

} // namespace

float timeMapRead(const float* input, std::size_t frames, double position) noexcept {
    if (input == nullptr || frames == 0 || !(position >= 0) || position > static_cast<double>(frames - 1)) {
        return 0.0f;
    }
    const auto index = static_cast<std::ptrdiff_t>(position);
    const double t = position - static_cast<double>(index);
    const auto last = static_cast<std::ptrdiff_t>(frames - 1);
    // Neighbours past either end repeat the edge sample, so the curve doesn't dive to 0 there.
    const auto at = [&](std::ptrdiff_t frame) { return static_cast<double>(sampleAt(input, frames, std::clamp<std::ptrdiff_t>(frame, 0, last))); };
    const double x1 = at(index);
    if (t == 0) {
        return static_cast<float>(x1);
    }
    const double x0 = at(index - 1), x2 = at(index + 1), x3 = at(index + 2);
    const double c1 = 0.5 * (x2 - x0);
    const double c2 = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3;
    const double c3 = 0.5 * (x3 - x0) + 1.5 * (x1 - x2);
    return static_cast<float>(((c3 * t + c2) * t + c1) * t + x1);
}

void TimeMapPath::jump(double target, double smoothFrames, float newGain) noexcept {
    if (target == position && newGain == gain) {
        return;
    }
    // A jump mid-fade drops the older path: only the latest two ever play.
    oldPosition = position;
    oldGain = gain;
    position = target;
    gain = newGain;
    fadeDone = 0;
    fadeFrames = smoothFrames >= 1 ? smoothFrames : 0;
}

float TimeMapPath::read(const float* input, std::size_t frames) noexcept {
    const float current = gain * timeMapRead(input, frames, position);
    if (fadeFrames <= 0) {
        return current;
    }
    const double t = fadeDone / fadeFrames;
    const float old = oldGain * timeMapRead(input, frames, oldPosition);
    fadeDone += 1;
    if (fadeDone >= fadeFrames) {
        fadeFrames = 0;
    }
    return static_cast<float>(std::cos(t * halfPi) * old + std::sin(t * halfPi) * current);
}

void TimeMapGrains::launch(const float* input, std::size_t frames, double start, int grainFrames) noexcept {
    const int hop = grainFrames / 2;
    double aligned = start;
    if (hasLast && input != nullptr) {
        // WSOLA: the previous grain will next play lastStart + hop onward. Pick the offset of the new
        // grain within ±range whose waveform matches that best (normalised correlation, every 4th
        // sample). Offset 0 is tried first and only a strictly better match replaces it.
        const auto target = static_cast<std::ptrdiff_t>(std::floor(lastStart)) + hop;
        const auto base = static_cast<std::ptrdiff_t>(std::floor(start));
        const int range = std::max(hop / 2, 1);
        double best = -1e300;
        int bestOffset = 0;
        for (int step = 0; step <= 2 * range; ++step) {
            const int offset = step % 2 == 0 ? step / 2 : -(step + 1) / 2;   // 0, −1, 1, −2, 2…
            double product = 0, energy = 0;
            for (int k = 0; k < hop; k += 4) {
                const double a = sampleAt(input, frames, target + k);
                const double b = sampleAt(input, frames, base + offset + k);
                product += a * b;
                energy += b * b;
            }
            const double score = energy > 0 ? product / std::sqrt(energy) : 0;
            if (score > best) {
                best = score;
                bestOffset = offset;
            }
        }
        aligned = start + bestOffset;
    }
    for (auto& grain : grains) {
        if (!grain.active) {
            grain = {true, aligned, 0, grainFrames};
            break;
        }
    }
    hasLast = true;
    lastStart = aligned;
}

float TimeMapGrains::read(const float* input, std::size_t frames, int grainFrames, bool normalize) noexcept {
    double sum = 0;
    double weight = 0;
    for (auto& grain : grains) {
        if (!grain.active) {
            continue;
        }
        // Periodic Hann: two at half-grain spacing sum to exactly 1.
        const int length = grain.length > 0 ? grain.length : grainFrames;
        const double window = 0.5 - 0.5 * std::cos(twoPi * grain.age / length);
        sum += window * timeMapRead(input, frames, grain.start + grain.age);
        weight += window;
        grain.age += 1;
        if (grain.age >= length) {
            grain.active = false;
        }
    }
    if (normalize && weight > 1e-3) {
        sum /= weight;
    }
    return static_cast<float>(sum);
}

} // namespace bake::dsp
