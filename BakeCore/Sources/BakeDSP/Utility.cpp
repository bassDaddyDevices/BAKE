#include "BakeDSP/Utility.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;
    double step(double x) noexcept {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
};

/// BS.1770-4 stage 1: the high shelf (+4 dB above about 1.7 kHz), for any sample rate.
Biquad shelf(double sampleRate) noexcept {
    const double f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196;
    const double k = std::tan(pi * f0 / sampleRate);
    const double vh = std::pow(10.0, gain / 20.0);
    const double vb = std::pow(vh, 0.4996667741545416);
    const double a0 = 1.0 + k / q + k * k;
    Biquad filter;
    filter.b0 = (vh + vb * k / q + k * k) / a0;
    filter.b1 = 2.0 * (k * k - vh) / a0;
    filter.b2 = (vh - vb * k / q + k * k) / a0;
    filter.a1 = 2.0 * (k * k - 1.0) / a0;
    filter.a2 = (1.0 - k / q + k * k) / a0;
    return filter;
}

/// BS.1770-4 stage 2: the high-pass at about 38 Hz.
Biquad highPass(double sampleRate) noexcept {
    const double f0 = 38.13547087602444, q = 0.5003270373238773;
    const double k = std::tan(pi * f0 / sampleRate);
    const double a0 = 1.0 + k / q + k * k;
    Biquad filter;
    filter.b0 = 1.0;
    filter.b1 = -2.0;
    filter.b2 = 1.0;
    filter.a1 = 2.0 * (k * k - 1.0) / a0;
    filter.a2 = (1.0 - k / q + k * k) / a0;
    return filter;
}

double dc(const double* offsets, int channel) noexcept {
    return offsets == nullptr ? 0.0 : offsets[channel];
}

double curve(UtilityFadeCurve shape, double t) noexcept {
    t = std::clamp(t, 0.0, 1.0);
    switch (shape) {
    case UtilityFadeCurve::linear: return t;
    case UtilityFadeCurve::equalPower: return std::sin(0.5 * pi * t);
    case UtilityFadeCurve::smooth: return 0.5 - 0.5 * std::cos(pi * t);
    }
    return t;
}

} // namespace

double utilityDcOffset(const float* input, std::size_t frames) noexcept {
    if (input == nullptr || frames == 0) {
        return 0;
    }
    double sum = 0;
    for (std::size_t i = 0; i < frames; ++i) {
        sum += std::isfinite(input[i]) ? static_cast<double>(input[i]) : 0.0;
    }
    return sum / static_cast<double>(frames);
}

double utilityIntegratedLoudness(const float* const* channels, int channelCount, std::size_t frames,
                                 const double* dcOffsets, double sampleRate) noexcept {
    if (channels == nullptr || channelCount <= 0 || frames == 0 || sampleRate <= 0) {
        return -1000;
    }
    const std::size_t hop = std::max<std::size_t>(static_cast<std::size_t>(std::llround(0.1 * sampleRate)), 1);
    const std::size_t hops = (frames + hop - 1) / hop;
    // Weighted K-weighted energy of each 100 ms hop (all channels summed with their channel weights).
    std::vector<double> energy(hops, 0.0);
    std::vector<std::size_t> lengths(hops, 0);
    for (std::size_t h = 0; h < hops; ++h) {
        lengths[h] = std::min(hop, frames - h * hop);
    }
    for (int channel = 0; channel < channelCount; ++channel) {
        if (channels[channel] == nullptr) {
            continue;
        }
        const double weight = channel >= 3 ? 1.41 : 1.0;
        Biquad stageOne = shelf(sampleRate), stageTwo = highPass(sampleRate);
        const double offset = dc(dcOffsets, channel);
        for (std::size_t h = 0; h < hops; ++h) {
            double sum = 0;
            for (std::size_t i = h * hop; i < h * hop + lengths[h]; ++i) {
                const double raw = std::isfinite(channels[channel][i]) ? static_cast<double>(channels[channel][i]) : 0.0;
                const double weighted = stageTwo.step(stageOne.step(raw - offset));
                sum += weighted * weighted;
            }
            energy[h] += weight * sum;
        }
    }
    // 400 ms blocks (4 hops) every hop; a file shorter than that is one block.
    std::vector<double> blocks;
    if (hops < 4) {
        double total = 0;
        for (double e : energy) total += e;
        blocks.push_back(total / static_cast<double>(frames));
    } else {
        for (std::size_t start = 0; start + 4 <= hops; ++start) {
            double total = 0;
            std::size_t samples = 0;
            for (std::size_t h = start; h < start + 4; ++h) {
                total += energy[h];
                samples += lengths[h];
            }
            blocks.push_back(total / static_cast<double>(samples));
        }
    }
    auto loudness = [](double meanSquare) { return -0.691 + 10.0 * std::log10(meanSquare); };
    double absoluteSum = 0;
    std::size_t absoluteCount = 0;
    for (double b : blocks) {
        if (b > 0 && loudness(b) > -70.0) {
            absoluteSum += b;
            ++absoluteCount;
        }
    }
    if (absoluteCount == 0) {
        return -1000;
    }
    const double relativeGate = loudness(absoluteSum / static_cast<double>(absoluteCount)) - 10.0;
    double sum = 0;
    std::size_t count = 0;
    for (double b : blocks) {
        if (b > 0 && loudness(b) > -70.0 && loudness(b) > relativeGate) {
            sum += b;
            ++count;
        }
    }
    return count == 0 ? -1000 : loudness(sum / static_cast<double>(count));
}

double utilityNormalizeGain(const float* const* channels, int channelCount, std::size_t frames, const double* dcOffsets,
                            UtilityNormalize mode, double targetDb, double sampleRate) noexcept {
    if (mode == UtilityNormalize::off || channels == nullptr || channelCount <= 0 || frames == 0) {
        return 1;
    }
    double measuredDb = 0;
    switch (mode) {
    case UtilityNormalize::off: return 1;
    case UtilityNormalize::peak: {
        double peak = 0;
        for (int channel = 0; channel < channelCount; ++channel) {
            if (channels[channel] == nullptr) continue;
            const double offset = dc(dcOffsets, channel);
            for (std::size_t i = 0; i < frames; ++i) {
                if (std::isfinite(channels[channel][i])) {
                    peak = std::max(peak, std::fabs(static_cast<double>(channels[channel][i]) - offset));
                }
            }
        }
        if (peak <= 0) return 1;
        measuredDb = 20.0 * std::log10(peak);
        break;
    }
    case UtilityNormalize::rms: {
        double sum = 0;
        std::size_t samples = 0;
        for (int channel = 0; channel < channelCount; ++channel) {
            if (channels[channel] == nullptr) continue;
            const double offset = dc(dcOffsets, channel);
            for (std::size_t i = 0; i < frames; ++i) {
                const double value = std::isfinite(channels[channel][i]) ? static_cast<double>(channels[channel][i]) - offset : 0.0;
                sum += value * value;
            }
            samples += frames;
        }
        if (samples == 0 || sum <= 0) return 1;
        measuredDb = 10.0 * std::log10(sum / static_cast<double>(samples));
        break;
    }
    case UtilityNormalize::loudness: {
        measuredDb = utilityIntegratedLoudness(channels, channelCount, frames, dcOffsets, sampleRate);
        if (measuredDb <= -999) return 1;
        break;
    }
    }
    return std::pow(10.0, (targetDb - measuredDb) / 20.0);
}

void utilityMonoSum(const float* const* channels, int channelCount, std::size_t frames, float* output) noexcept {
    if (channels == nullptr || output == nullptr || channelCount < 1) {
        return;
    }
    if (channelCount == 1 && channels[0] != nullptr) {
        std::copy(channels[0], channels[0] + frames, output);
        return;
    }
    for (std::size_t i = 0; i < frames; ++i) {
        double sum = 0;
        for (int channel = 0; channel < channelCount; ++channel) {
            const float* source = channels[channel];
            const double value = source != nullptr ? static_cast<double>(source[i]) : 0.0;
            sum += std::isfinite(value) ? value : 0.0;
        }
        output[i] = static_cast<float>(sum / static_cast<double>(channelCount));
    }
}

void renderUtility(const UtilityControls& controls, int channel, int channelCount, const float* input, float* output,
                   double dcOffset, std::size_t frameOffset, std::size_t count) noexcept {
    if (input == nullptr || output == nullptr) {
        return;
    }
    (void)channelCount;
    const bool balances = channel == 0 || channel == 1;
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        double value = std::isfinite(input[i]) ? static_cast<double>(input[i]) : 0.0;
        if (dcOffset != 0.0) {
            value -= dcOffset;
        }
        if (controls.normalizeGain != 1.0) {
            value *= controls.normalizeGain;
        }
        const float decibels = controls.gain.valueAt(frame);
        if (decibels != 0.0f) {
            value *= std::pow(10.0, static_cast<double>(decibels) / 20.0);
        }
        if (controls.polarity < 0) {
            value = -value;
        }
        if (balances) {
            const double balance = std::clamp(static_cast<double>(controls.balance.valueAt(frame)), -1.0, 1.0);
            if (balance != 0.0) {
                // Equal power, attenuating only the far side: the near side stays at unity.
                const double angle = (balance + 1.0) * pi / 4.0;
                value *= channel == 0 ? std::min(1.0, std::sqrt(2.0) * std::cos(angle)) : std::min(1.0, std::sqrt(2.0) * std::sin(angle));
            }
        }
        const double local = static_cast<double>(frame) - static_cast<double>(controls.contentStart);
        if (controls.fadeInFrames > 0 && local >= 0.0 && local < controls.fadeInFrames) {
            value *= curve(controls.fadeCurve, local / controls.fadeInFrames);
        }
        if (controls.fadeOutFrames > 0 && controls.totalFrames > 0) {
            const double remaining = static_cast<double>(controls.totalFrames - 1) - static_cast<double>(frame);
            if (remaining < controls.fadeOutFrames) {
                value *= curve(controls.fadeCurve, remaining / controls.fadeOutFrames);
            }
        }
        output[i] = std::isfinite(value) ? static_cast<float>(value) : 0.0f;
    }
}

} // namespace bake::dsp
