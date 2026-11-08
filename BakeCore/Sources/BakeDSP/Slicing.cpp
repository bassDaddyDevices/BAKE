#include "BakeDSP/Slicing.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

double decibels(double energy) noexcept {
    return 10.0 * std::log10(std::max(energy, 1e-12));
}

/// −1…1 from (seed, index), the same on every machine (splitmix64).
double signedHash(std::uint32_t seed, std::size_t index) noexcept {
    std::uint64_t x = (static_cast<std::uint64_t>(seed) << 32) ^ static_cast<std::uint64_t>(index);
    x += 0x9E3779B97F4A7C15ull;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
    x ^= x >> 31;
    return static_cast<double>(x >> 11) * 0x1.0p-53 * 2.0 - 1.0;
}

std::size_t hops(double seconds, const SliceSettings& settings) noexcept {
    return std::max<std::size_t>(1, static_cast<std::size_t>(std::lround(seconds * settings.sampleRate / static_cast<double>(settings.hop))));
}

} // namespace

void sliceEnergy(const float* mono, std::size_t frames, std::size_t hop, double* energy) noexcept {
    if (mono == nullptr || energy == nullptr || hop == 0) return;
    for (std::size_t start = 0, index = 0; start < frames; start += hop, ++index) {
        const std::size_t end = std::min(frames, start + hop);
        double sum = 0;
        for (std::size_t frame = start; frame < end; ++frame) {
            sum += static_cast<double>(mono[frame]) * static_cast<double>(mono[frame]);
        }
        energy[index] = sum / static_cast<double>(end - start);
    }
}

std::size_t sliceOnsets(const double* energy, std::size_t count, const SliceSettings& settings,
                        std::size_t* onsets, std::size_t capacity) noexcept {
    if (energy == nullptr || onsets == nullptr || settings.hop == 0) return 0;
    const std::size_t window = hops(0.1, settings);
    const std::size_t refractory = hops(0.03, settings);
    const std::size_t reach = hops(0.05, settings);
    std::size_t found = 0;
    bool wasOnset = false;
    std::size_t last = 0;
    double running = 0;  // sum of the `window` hops before this one
    for (std::size_t hop = 0; hop < count; ++hop) {
        const std::size_t before = std::min(hop, window);
        const double background = before > 0 ? running / static_cast<double>(before) : 0;
        const double level = decibels(energy[hop]);
        const bool isOnset = level >= settings.thresholdDb && level - decibels(background) >= settings.sensitivityDb;
        if (isOnset && !wasOnset && (found == 0 || hop - last >= refractory) && found < capacity) {
            std::size_t start = hop;
            if (settings.backTrack) {
                // The quietest hop of the attack; the latest of equal ones, so the cut sits closest to the hit.
                std::size_t quietest = hop;
                for (std::size_t back = hop > reach ? hop - reach : 0; back < hop; ++back) {
                    if (energy[back] <= energy[quietest]) quietest = back;
                }
                start = quietest == hop ? hop : quietest + 1;
            }
            onsets[found++] = start * settings.hop;
            last = hop;
        }
        wasOnset = isOnset;
        running += energy[hop];
        if (hop >= window) running -= energy[hop - window];
    }
    return found;
}

std::size_t sliceRanges(const std::size_t* boundaries, std::size_t count, std::size_t totalFrames,
                        std::size_t minFrames, std::size_t maxFrames, double jitter, std::uint32_t seed,
                        std::size_t* starts, std::size_t* ends, std::size_t capacity) noexcept {
    if (boundaries == nullptr || starts == nullptr || ends == nullptr || capacity == 0) return 0;
    maxFrames = std::max<std::size_t>(maxFrames, 1);
    // Joined slices go into `starts`/`ends` first (never more than `count`, so they fit when capacity ≥ count),
    // then long ones are cut from the back so nothing is overwritten before it's read.
    std::size_t joined = 0;
    for (std::size_t i = 0; i < count && joined < capacity; ++i) {
        const std::size_t start = boundaries[i];
        const std::size_t end = i + 1 < count ? boundaries[i + 1] : totalFrames;
        if (start >= end) continue;
        if (joined > 0 && ends[joined - 1] - starts[joined - 1] < minFrames) {
            ends[joined - 1] = end;  // the short one before takes this one in
        } else {
            starts[joined] = start;
            ends[joined] = end;
            ++joined;
        }
    }
    if (joined > 1 && ends[joined - 1] - starts[joined - 1] < minFrames) {
        ends[joined - 2] = ends[joined - 1];
        --joined;
    }
    std::size_t total = 0;
    for (std::size_t i = 0; i < joined; ++i) {
        total += (ends[i] - starts[i] + maxFrames - 1) / maxFrames;
    }
    std::size_t out = std::min(total, capacity);
    std::size_t write = total;
    for (std::size_t i = joined; i-- > 0;) {
        const std::size_t start = starts[i], end = ends[i];
        const std::size_t pieces = (end - start + maxFrames - 1) / maxFrames;
        for (std::size_t piece = pieces; piece-- > 0;) {
            --write;
            if (write >= capacity) continue;
            starts[write] = start + piece * maxFrames;
            ends[write] = std::min(end, start + (piece + 1) * maxFrames);
        }
    }
    if (jitter > 0) {
        for (std::size_t i = 0; i < out; ++i) {
            const double length = static_cast<double>(ends[i] - starts[i]) * (1.0 + std::clamp(jitter, 0.0, 1.0) * signedHash(seed, i));
            ends[i] = std::min(totalFrames, starts[i] + std::max<std::size_t>(1, static_cast<std::size_t>(std::lround(length))));
        }
    }
    return out;
}

std::size_t sliceSnap(const float* mono, std::size_t firstFrame, std::size_t count, std::size_t frame,
                      std::size_t radius) noexcept {
    if (mono == nullptr || count < 2) return frame;
    const std::size_t lower = std::max(firstFrame + 1, frame > radius ? frame - radius : 0);
    const std::size_t upper = std::min(firstFrame + count - 1, frame + radius);
    std::size_t best = frame;
    std::size_t bestDistance = radius + 1;
    for (std::size_t f = lower; f <= upper; ++f) {
        const float previous = mono[f - 1 - firstFrame], current = mono[f - firstFrame];
        const bool crosses = current == 0.0f || (previous < 0.0f) != (current < 0.0f);
        if (!crosses) continue;
        const std::size_t distance = f > frame ? f - frame : frame - f;
        if (distance < bestDistance) {
            best = f;
            bestDistance = distance;
        }
    }
    return best;
}

} // namespace bake::dsp
