#include "BakeDSP/TapeDegrade.h"

#include <algorithm>
#include <cmath>

#include "BakeDSP/TimeMap.h"

namespace bake::dsp {

namespace {

constexpr double twoPi = 6.283185307179586;
constexpr double dropoutBlockSeconds = 0.05;
constexpr double dropoutRampSeconds = 0.005;
constexpr double dropoutFloor = 0.1;

/// SplitMix64 of (seed, index), mapped to 0…1.
double unit(std::uint64_t seed, std::uint64_t index) noexcept {
    std::uint64_t z = seed * 0x9E3779B97F4A7C15ull + index;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return static_cast<double>(z >> 11) * (1.0 / 9007199254740992.0);
}

bool dropped(const TapeDegradeControls& c, std::int64_t block, std::size_t blockFrames) noexcept {
    if (block < 0) {
        return false;
    }
    const double chance = c.dropouts.valueAt(static_cast<std::size_t>(block) * blockFrames);
    return unit(c.seed ^ 0xD0ull, static_cast<std::uint64_t>(block)) < chance;
}

/// Gain at `frame`: a dropped block sits at 0.1, ramping over 5 ms where its neighbour is not dropped.
double dropoutGain(const TapeDegradeControls& c, std::size_t frame, std::size_t blockFrames, std::size_t rampFrames) noexcept {
    const auto block = static_cast<std::int64_t>(frame / blockFrames);
    if (!dropped(c, block, blockFrames)) {
        return 1;
    }
    const std::size_t position = frame % blockFrames;
    double gain = dropoutFloor;
    if (!dropped(c, block - 1, blockFrames) && position < rampFrames) {
        gain = 1 + (dropoutFloor - 1) * static_cast<double>(position) / static_cast<double>(rampFrames);
    }
    const std::size_t fromEnd = blockFrames - 1 - position;
    if (!dropped(c, block + 1, blockFrames) && fromEnd < rampFrames) {
        gain = std::max(gain, 1 + (dropoutFloor - 1) * static_cast<double>(fromEnd) / static_cast<double>(rampFrames));
    }
    return gain;
}

} // namespace

void renderTapeDegrade(TapeDegradeState* state, const TapeDegradeControls& controls,
                       const float* input, std::size_t inputFrames, std::size_t channel,
                       float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || input == nullptr || output == nullptr) {
        return;
    }
    TapeDegradeState& s = *state;
    const double rate = controls.sampleRate;
    const auto blockFrames = std::max<std::size_t>(1, static_cast<std::size_t>(std::lround(dropoutBlockSeconds * rate)));
    const auto rampFrames = std::max<std::size_t>(1, static_cast<std::size_t>(std::lround(dropoutRampSeconds * rate)));
    // A second channel's wobble runs a quarter cycle ahead, for width.
    const double offset = 0.25 * static_cast<double>(channel);
    const std::size_t channels = std::max<std::size_t>(controls.channelCount, 1);

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double wobbleMs = controls.wow.valueAt(frame) * std::sin(twoPi * (s.wowPhase + offset))
                              + controls.flutter.valueAt(frame) * std::sin(twoPi * (s.flutterPhase + offset));
        const double position = static_cast<double>(frame) - wobbleMs * 0.001 * rate;
        double x = timeMapRead(input, inputFrames, position);
        s.wowPhase = std::fmod(s.wowPhase + controls.wowRate.valueAt(frame) / rate, 1.0);
        s.flutterPhase = std::fmod(s.flutterPhase + controls.flutterRate.valueAt(frame) / rate, 1.0);

        const double saturationDb = controls.saturation.valueAt(frame);
        if (saturationDb > 0) {
            const double g = std::pow(10.0, saturationDb / 20);
            x = std::tanh(g * x) / std::tanh(g);
        }
        const double a = std::exp(-twoPi * controls.tone.valueAt(frame) / rate);
        s.lowpass = (1 - a) * x + a * s.lowpass;
        double wet = s.lowpass;

        const double hiss = std::pow(10.0, controls.hiss.valueAt(frame) / 20);
        wet += hiss * (2 * unit(controls.seed, static_cast<std::uint64_t>(frame) * channels + channel) - 1);
        wet *= dropoutGain(controls, frame, blockFrames, rampFrames);

        const float mix = controls.mix.valueAt(frame);
        const float dry = frame < inputFrames ? input[frame] : 0.0f;
        const float value = mix * static_cast<float>(wet) + (1 - mix) * dry;
        if (!std::isfinite(value)) {
            s = TapeDegradeState();
            output[i] = 0;
            continue;
        }
        output[i] = value;
    }
}

} // namespace bake::dsp
