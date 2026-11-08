#include "BakeDSP/GranularCloud.h"

#include <algorithm>
#include <cmath>

#include "BakeDSP/TimeMap.h"

namespace bake::dsp {

namespace {

constexpr double pi = 3.141592653589793;
/// Hash streams of the extra grains, so they never share numbers with the first grain of a slot.
constexpr std::uint64_t extraGrainStream = 0xC3A5C85C97CB3127ull;
constexpr std::uint64_t extraCountStream = 0x1B873593A5A5A5A5ull;

/// SplitMix64 of (seed, index), mapped to 0…1.
double unit(std::uint64_t seed, std::uint64_t index) noexcept {
    std::uint64_t z = seed * 0x9E3779B97F4A7C15ull + index;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return static_cast<double>(z >> 11) * (1.0 / 9007199254740992.0);
}

std::size_t slotStart(std::uint64_t k, double sampleRate) noexcept {
    return static_cast<std::size_t>(std::floor(static_cast<double>(k) * sampleRate / granularSlotsPerSecond));
}

} // namespace

void renderGranularCloud(const GranularCloudControls& controls, const float* input, std::size_t inputFrames,
                         std::size_t channel, std::size_t channelCount,
                         float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (input == nullptr || output == nullptr || count == 0) {
        return;
    }
    const double rate = controls.sampleRate;
    std::fill(output, output + count, 0.0f);
    const std::size_t first = frameOffset;
    const std::size_t last = frameOffset + count; // exclusive
    const double maxSizeFrames = granularMaxSizeMs * 0.001 * rate;
    const double slotsPerFrame = granularSlotsPerSecond / rate;
    const auto lowest = static_cast<std::int64_t>(std::floor((static_cast<double>(first) - maxSizeFrames) * slotsPerFrame)) - 1;
    const auto highest = static_cast<std::int64_t>(std::ceil(static_cast<double>(last) * slotsPerFrame));
    const std::uint64_t seed = controls.seed;
    const std::uint64_t extraSeed = seed ^ extraGrainStream;
    const std::uint64_t countSeed = seed ^ extraCountStream;

    // One grain starting at `start`: its offset, pitch, direction and pan come from the hash of
    // (randomSeed, base …) and (panSeed, panIndex); everything else is read at its start frame.
    // `density` is the slot's, which sets the loudness normalisation.
    const auto grain = [&](std::size_t start, double density, std::uint64_t randomSeed, std::uint64_t base,
                           std::uint64_t panSeed, std::uint64_t panIndex) {
        const auto size = static_cast<std::size_t>(std::max(1.0, std::round(controls.size.valueAt(start) * 0.001 * rate)));
        if (start + size <= first) {
            return;
        }
        const double offset = (unit(randomSeed, base) - 0.5) * 2 * controls.spray.valueAt(start) * 0.001 * rate;
        const double semitones = controls.pitch.valueAt(start) + (unit(randomSeed, base + 1) - 0.5) * 2 * controls.pitchSpread.valueAt(start);
        double speed = std::pow(2.0, semitones / 12);
        if (unit(randomSeed, base + 2) < controls.reverse.valueAt(start)) {
            speed = -speed;
        }
        double pan = 1;
        if (channelCount >= 2) {
            const double position = 0.5 + (unit(panSeed, panIndex) - 0.5) * controls.stereoSpread.valueAt(start);
            pan = channel % 2 == 0 ? std::cos(position * pi / 2) : std::sin(position * pi / 2);
        }
        const double norm = 1 / std::sqrt(std::max(1.0, density * static_cast<double>(size) / rate));
        const double centre = static_cast<double>(start) + offset;
        const double half = static_cast<double>(size) / 2;
        const std::size_t from = std::max(start, first);
        const std::size_t to = std::min(start + size, last);
        for (std::size_t n = from; n < to; ++n) {
            const double j = static_cast<double>(n - start);
            const double window = 0.5 - 0.5 * std::cos(2 * pi * j / static_cast<double>(size));
            const double value = timeMapRead(input, inputFrames, centre + (j - half) * speed);
            output[n - first] += static_cast<float>(window * value * pan * norm);
        }
    };

    for (std::int64_t slot = std::max<std::int64_t>(lowest, 0); slot <= highest; ++slot) {
        const auto k = static_cast<std::uint64_t>(slot);
        const std::size_t start = slotStart(k, rate);
        if (start >= last) {
            break;
        }
        const double density = controls.density.valueAt(start);
        const double perSlot = density / granularSlotsPerSecond;
        if (unit(seed, k * 4 + 3) >= perSlot) {
            continue;
        }
        grain(start, density, seed, k * 4, seed ^ 0x5Aull, k);
        if (perSlot <= 1) {
            continue; // up to 200 grains a second: one grain per slot, exactly as it always was
        }
        // Past 200 a second a slot holds several grains: floor(perSlot) of them, plus one more with the
        // fractional chance. Each extra grain starts at its own spot inside the slot.
        const double whole = std::floor(perSlot);
        const std::uint64_t grains = std::min<std::uint64_t>(
            static_cast<std::uint64_t>(whole) + (unit(countSeed, k) < perSlot - whole ? 1 : 0), granularMaxGrainsPerSlot);
        const std::size_t slotFrames = std::max<std::size_t>(slotStart(k + 1, rate) - start, 1);
        for (std::uint64_t e = 1; e < grains; ++e) {
            const std::uint64_t id = k * granularMaxGrainsPerSlot + e;
            const std::size_t at = start + static_cast<std::size_t>(unit(extraSeed, id * 4 + 3) * static_cast<double>(slotFrames));
            if (at >= last) {
                continue;
            }
            grain(at, density, extraSeed, id * 4, extraSeed ^ 0x5Aull, id);
        }
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float mix = controls.mix.valueAt(frame);
        const float dry = frame < inputFrames ? input[frame] : 0.0f;
        const float value = mix * output[i] + (1 - mix) * dry;
        output[i] = std::isfinite(value) ? value : 0.0f;
    }
}

} // namespace bake::dsp
