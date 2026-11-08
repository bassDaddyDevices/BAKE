#include "BakeDSP/Dynamics.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;
constexpr double floorDb = -120.0;
constexpr double dbToNeper = 0.11512925464970229;   // ln(10) / 20

double toDb(double amplitude) noexcept {
    return amplitude <= 1e-6 ? floorDb : std::max(20.0 * std::log10(amplitude), floorDb);
}

/// Smoothing factor for "falls to 10% in `ms`"; 0 for no smoothing.
double settle(double ms, double sampleRate) noexcept {
    const double frames = ms * 0.001 * sampleRate;
    return frames < 1.0 ? 0.0 : std::pow(0.1, 1.0 / frames);
}

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

/// Reduction (dB, ≥ 0) for a level `x` dB past the threshold, with a quadratic knee of width `knee`.
double curve(double x, double slope, double knee) noexcept {
    if (knee > 0 && 2.0 * x < -knee) {
        return 0.0;
    }
    if (knee > 0 && 2.0 * std::abs(x) <= knee) {
        return slope * (x + knee / 2.0) * (x + knee / 2.0) / (2.0 * knee);
    }
    return x > 0 ? slope * x : 0.0;
}

} // namespace

void dynamicsLevels(const AudioInput& detector, int channel, bool rms, double windowMs, double sampleRate,
                    std::size_t frames, float* levelsDb) noexcept {
    if (levelsDb == nullptr) {
        return;
    }
    if (detector.channelCount == 0) {
        std::fill(levelsDb, levelsDb + frames, static_cast<float>(floorDb));
        return;
    }
    const std::size_t source = std::min<std::size_t>(static_cast<std::size_t>(std::max(channel, 0)), detector.channelCount - 1);
    if (!rms) {
        for (std::size_t i = 0; i < frames; ++i) {
            levelsDb[i] = static_cast<float>(toDb(std::abs(static_cast<double>(detector.sample(source, i)))));
        }
        return;
    }
    // Centred running mean square. The sum is rebuilt every 2^16 frames so rounding never builds up.
    const long long radius = std::max<long long>(static_cast<long long>(windowMs * 0.001 * sampleRate / 2.0), 1);
    auto power = [&](long long i) {
        if (i < 0 || i >= static_cast<long long>(frames)) {
            return 0.0;
        }
        const double v = detector.sample(source, static_cast<std::size_t>(i));
        return v * v;
    };
    double sum = 0;
    for (long long i = -radius; i <= radius; ++i) {
        sum += power(i);
    }
    const double width = static_cast<double>(2 * radius + 1);
    for (long long i = 0; i < static_cast<long long>(frames); ++i) {
        if ((i & 0xFFFF) == 0 && i > 0) {
            sum = 0;
            for (long long k = i - radius; k <= i + radius; ++k) {
                sum += power(k);
            }
        }
        levelsDb[i] = static_cast<float>(toDb(std::sqrt(std::max(sum, 0.0) / width)));
        sum += power(i + radius + 1) - power(i - radius);
    }
}

void dynamicsLevelsFiltered(const AudioInput& detector, int channel, double highPassHz, double lowPassHz, bool rms,
                            double windowMs, double sampleRate, std::size_t frames, float* levelsDb, float* scratch) noexcept {
    if (levelsDb == nullptr || scratch == nullptr) {
        return;
    }
    if (detector.channelCount == 0) {
        std::fill(levelsDb, levelsDb + frames, static_cast<float>(floorDb));
        return;
    }
    const std::size_t source = std::min<std::size_t>(static_cast<std::size_t>(std::max(channel, 0)), detector.channelCount - 1);
    Biquad high, low;
    const bool useHigh = highPassHz > 0 && highPassHz < sampleRate * 0.5;
    const bool useLow = lowPassHz > 0 && lowPassHz < sampleRate * 0.5;
    auto design = [&](Biquad& filter, double hertz, bool isHigh) {
        const double q = 0.7071067811865476;
        const double w = 2.0 * pi * hertz / sampleRate;
        const double alpha = std::sin(w) / (2.0 * q), cosine = std::cos(w);
        const double a0 = 1.0 + alpha;
        filter.b0 = (isHigh ? (1.0 + cosine) / 2.0 : (1.0 - cosine) / 2.0) / a0;
        filter.b1 = (isHigh ? -(1.0 + cosine) : (1.0 - cosine)) / a0;
        filter.b2 = filter.b0;
        filter.a1 = -2.0 * cosine / a0;
        filter.a2 = (1.0 - alpha) / a0;
    };
    if (useHigh) design(high, highPassHz, true);
    if (useLow) design(low, lowPassHz, false);
    for (std::size_t i = 0; i < frames; ++i) {
        double x = detector.sample(source, i);
        if (useHigh) x = high.step(x);
        if (useLow) x = low.step(x);
        scratch[i] = static_cast<float>(x);
    }
    // The levels of the filtered signal: the same rules as `dynamicsLevels`, over `scratch`.
    if (!rms) {
        for (std::size_t i = 0; i < frames; ++i) {
            levelsDb[i] = static_cast<float>(toDb(std::abs(static_cast<double>(scratch[i]))));
        }
        return;
    }
    const long long radius = std::max<long long>(static_cast<long long>(windowMs * 0.001 * sampleRate / 2.0), 1);
    auto power = [&](long long i) {
        if (i < 0 || i >= static_cast<long long>(frames)) {
            return 0.0;
        }
        const double v = scratch[i];
        return v * v;
    };
    double sum = 0;
    for (long long i = -radius; i <= radius; ++i) {
        sum += power(i);
    }
    const double width = static_cast<double>(2 * radius + 1);
    for (long long i = 0; i < static_cast<long long>(frames); ++i) {
        if ((i & 0xFFFF) == 0 && i > 0) {
            sum = 0;
            for (long long k = i - radius; k <= i + radius; ++k) {
                sum += power(k);
            }
        }
        levelsDb[i] = static_cast<float>(toDb(std::sqrt(std::max(sum, 0.0) / width)));
        sum += power(i + radius + 1) - power(i - radius);
    }
}

void dynamicsLink(float* const* levelsDb, int channelCount, std::size_t frames, double link) noexcept {
    if (levelsDb == nullptr || channelCount < 2 || link <= 0) {
        return;
    }
    const double amount = std::min(link, 1.0);
    for (std::size_t i = 0; i < frames; ++i) {
        float loudest = levelsDb[0][i];
        for (int c = 1; c < channelCount; ++c) {
            loudest = std::max(loudest, levelsDb[c][i]);
        }
        for (int c = 0; c < channelCount; ++c) {
            levelsDb[c][i] = static_cast<float>(levelsDb[c][i] + amount * (loudest - levelsDb[c][i]));
        }
    }
}

void dynamicsGainCurve(const float* levelsDb, std::size_t frames, const DynamicsSettings& settings, float* gainDb) noexcept {
    if (levelsDb == nullptr || gainDb == nullptr || frames == 0) {
        return;
    }
    const bool compressor = settings.mode == DynamicsMode::compressor;
    const double range = std::max(settings.rangeDb, 0.0);
    // 1. The static curve: the reduction each frame asks for.
    std::vector<float> wanted(frames);
    bool open = true;
    for (std::size_t i = 0; i < frames; ++i) {
        const double level = levelsDb[i];
        const double threshold = settings.threshold.valueAt(i);
        const double ratio = std::max(static_cast<double>(settings.ratio.valueAt(i)), 1.0);
        double reduction = 0;
        if (compressor) {
            const double slope = ratio >= 100.0 ? 1.0 : 1.0 - 1.0 / ratio;
            reduction = curve(level - threshold, slope, settings.kneeDb);
        } else {
            if (level > threshold) {
                open = true;
            } else if (level < threshold - settings.hysteresisDb) {
                open = false;
            }
            if (!open) {
                const double slope = settings.mode == DynamicsMode::gate ? 1000.0 : ratio - 1.0;
                reduction = std::min(curve(threshold - level, slope, settings.kneeDb), range);
            }
        }
        wanted[i] = static_cast<float>(reduction);
    }
    // 2. Look-ahead (backwards in time) and hold/release (forwards), in the reduction domain.
    const double ahead = settle(settings.attackMs, settings.sampleRate);
    const double back = settle(settings.releaseMs, settings.sampleRate);
    const long long holdFrames = static_cast<long long>(settings.holdMs * 0.001 * settings.sampleRate);
    std::vector<float> early(frames);
    if (compressor) {
        // Reduction arrives on the frame that asks for it and starts easing in before it.
        double carried = 0;
        for (std::size_t i = frames; i-- > 0;) {
            carried = std::max(static_cast<double>(wanted[i]), carried * ahead);
            early[i] = static_cast<float>(carried);
        }
        double held = 0;
        long long counter = 0;
        for (std::size_t i = 0; i < frames; ++i) {
            const double target = early[i];
            if (target >= held) {
                held = target;
                counter = holdFrames;
            } else if (counter > 0) {
                --counter;
            } else {
                held = target + (held - target) * back;
            }
            gainDb[i] = static_cast<float>(-held);
        }
    } else {
        // Same shape mirrored: the gate opens early (less reduction ahead of the signal) and closes slowly.
        double carried = 0;
        for (std::size_t i = frames; i-- > 0;) {
            carried = std::max(range - static_cast<double>(wanted[i]), carried * ahead);
            early[i] = static_cast<float>(range - carried);
        }
        double held = early[0];
        long long counter = 0;
        for (std::size_t i = 0; i < frames; ++i) {
            const double target = early[i];
            if (target <= held) {
                held = target;
                counter = holdFrames;
            } else if (counter > 0) {
                --counter;
            } else {
                held = target - (target - held) * back;
            }
            gainDb[i] = static_cast<float>(-held);
        }
    }
}

double dynamicsLoudness(const AudioInput& input, const float* const* gainDb, int curveCount, double sampleRate) noexcept {
    const std::size_t frames = input.frames;
    if (input.channelCount == 0 || frames == 0 || sampleRate <= 0) {
        return -1000;
    }
    const std::size_t hop = std::max<std::size_t>(static_cast<std::size_t>(std::llround(0.1 * sampleRate)), 1);
    const std::size_t hops = (frames + hop - 1) / hop;
    std::vector<double> energy(hops, 0.0);
    for (std::size_t channel = 0; channel < input.channelCount; ++channel) {
        const double weight = channel >= 3 ? 1.41 : 1.0;
        const float* curveForChannel = nullptr;
        if (gainDb != nullptr && curveCount > 0) {
            curveForChannel = gainDb[curveCount == 1 ? 0 : std::min<std::size_t>(channel, static_cast<std::size_t>(curveCount) - 1)];
        }
        Biquad stageOne = shelf(sampleRate), stageTwo = highPass(sampleRate);
        for (std::size_t h = 0; h < hops; ++h) {
            double sum = 0;
            const std::size_t end = std::min((h + 1) * hop, frames);
            for (std::size_t i = h * hop; i < end; ++i) {
                double raw = input.sample(channel, i);
                if (!std::isfinite(raw)) {
                    raw = 0;
                }
                if (curveForChannel != nullptr) {
                    raw *= std::exp(static_cast<double>(curveForChannel[i]) * dbToNeper);
                }
                const double weighted = stageTwo.step(stageOne.step(raw));
                sum += weighted * weighted;
            }
            energy[h] += weight * sum;
        }
    }
    auto lengthOf = [&](std::size_t h) { return std::min(hop, frames - h * hop); };
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
                samples += lengthOf(h);
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

void dynamicsRender(const AudioInput& input, const float* const* gainDb, int curveCount, const ParameterSignal& makeup,
                    double extraMakeupDb, const ParameterSignal& mix, float* const* outputs, int channelCount,
                    std::size_t frameOffset, std::size_t count) noexcept {
    if (outputs == nullptr) {
        return;
    }
    for (int channel = 0; channel < channelCount; ++channel) {
        float* out = outputs[channel];
        if (out == nullptr) {
            continue;
        }
        const float* curveForChannel = nullptr;
        if (gainDb != nullptr && curveCount > 0) {
            curveForChannel = gainDb[curveCount == 1 ? 0 : std::min(channel, curveCount - 1)];
        }
        for (std::size_t i = 0; i < count; ++i) {
            const std::size_t frame = frameOffset + i;
            const double dry = input.sample(static_cast<std::size_t>(channel), frame);
            const double decibels = (curveForChannel != nullptr ? static_cast<double>(curveForChannel[frame]) : 0.0)
                + static_cast<double>(makeup.valueAt(frame)) + extraMakeupDb;
            const double wet = dry * std::exp(decibels * dbToNeper);
            const double amount = std::clamp(static_cast<double>(mix.valueAt(frame)), 0.0, 1.0);
            out[i] = static_cast<float>(dry + (wet - dry) * amount);
        }
    }
}

} // namespace bake::dsp
