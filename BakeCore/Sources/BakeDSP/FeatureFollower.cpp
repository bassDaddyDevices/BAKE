#include "BakeDSP/FeatureFollower.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

#include "BakeDSP/Fft.h"

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;
constexpr double silentMeanSquare = 1e-10;   // -100 dBFS

double mono(const AudioInput& input, std::size_t frame) noexcept {
    if (input.channelCount == 0) {
        return 0;
    }
    double sum = 0;
    for (std::size_t channel = 0; channel < input.channelCount; ++channel) {
        sum += input.sample(channel, frame);
    }
    return sum / static_cast<double>(input.channelCount);
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

} // namespace

std::size_t featureFrameSize(double sampleRate) noexcept {
    return nextPowerOfTwo(static_cast<std::size_t>(std::max(sampleRate, 8000.0) * 0.0213));
}

std::size_t featureHop(double sampleRate) noexcept {
    return featureFrameSize(sampleRate) / 4;
}

std::size_t featureHopCount(std::size_t frames, double sampleRate) noexcept {
    return frames / featureHop(sampleRate) + 2;
}

std::size_t featureScratchDoubles(double sampleRate) noexcept {
    return featureFrameSize(sampleRate) * 6 + 8;
}

void featureFrames(const AudioInput& input, const FeatureSettings& settings, std::size_t firstHop, std::size_t count,
                   double* scratch, double* values) noexcept {
    const std::size_t size = featureFrameSize(settings.sampleRate);
    const std::size_t hop = size / 4;
    const std::size_t bins = size / 2 + 1;
    double* real = scratch;
    double* imaginary = real + size;
    double* window = imaginary + size;
    double* cosines = window + size;
    double* sines = cosines + size / 2;
    double* previous = sines + size / 2;
    double* current = previous + bins;
    fftTwiddles(size, cosines, sines);
    for (std::size_t i = 0; i < size; ++i) {
        window[i] = 0.5 - 0.5 * std::cos(2.0 * pi * static_cast<double>(i) / static_cast<double>(size));
    }
    const double binWidth = settings.sampleRate / static_cast<double>(size);
    const std::size_t top = size / 2;
    std::size_t low = static_cast<std::size_t>(std::max(std::ceil(settings.lowCut / binWidth), 1.0));
    std::size_t high = static_cast<std::size_t>(std::max(std::floor(settings.highCut / binWidth), 1.0));
    low = std::min(low, top);
    high = std::min(std::max(high, low), top);
    const double scale = 1.0 / static_cast<double>(size);
    const double nan = std::numeric_limits<double>::quiet_NaN();

    // Fills `out` with magnitudes and returns the frame's mean square, peak and zero crossings (unwindowed).
    struct Stats { double meanSquare, peak; std::size_t crossings; };
    auto analyse = [&](std::size_t h, double* out) {
        const long long start = static_cast<long long>(h * hop) - static_cast<long long>(size / 2);
        Stats stats{0, 0, 0};
        double last = 0;
        for (std::size_t i = 0; i < size; ++i) {
            const long long frame = start + static_cast<long long>(i);
            const double sample = frame < 0 ? 0.0 : mono(input, static_cast<std::size_t>(frame));
            real[i] = window[i] * sample;
            imaginary[i] = 0.0;
            stats.meanSquare += sample * sample;
            stats.peak = std::max(stats.peak, std::abs(sample));
            if (i > 0 && ((sample >= 0) != (last >= 0))) {
                ++stats.crossings;
            }
            last = sample;
        }
        stats.meanSquare /= static_cast<double>(size);
        fft(real, imaginary, size, cosines, sines);
        for (std::size_t k = 0; k < bins; ++k) {
            out[k] = std::sqrt(real[k] * real[k] + imaginary[k] * imaginary[k]) * scale;
        }
        return stats;
    };

    if (settings.feature == Feature::flux) {
        if (firstHop == 0) {
            std::fill(previous, previous + bins, 0.0);
        } else {
            analyse(firstHop - 1, previous);
        }
    }
    for (std::size_t n = 0; n < count; ++n) {
        const Stats stats = analyse(firstHop + n, current);
        double result = nan;
        const bool silent = stats.meanSquare < silentMeanSquare;
        switch (settings.feature) {
        case Feature::flux: {
            double rise = 0;
            for (std::size_t k = low; k <= high; ++k) {
                rise += std::max(0.0, std::log1p(1000.0 * current[k]) - std::log1p(1000.0 * previous[k]));
            }
            result = rise;
            break;
        }
        case Feature::zeroCrossing:
            result = silent ? nan : static_cast<double>(stats.crossings) / static_cast<double>(size - 1);
            break;
        case Feature::crest:
            result = silent ? nan : 20.0 * std::log10(stats.peak / std::sqrt(stats.meanSquare));
            break;
        case Feature::centroid:
        case Feature::bandwidth: {
            double weight = 0, moment = 0;
            for (std::size_t k = low; k <= high; ++k) {
                weight += current[k];
                moment += current[k] * static_cast<double>(k) * binWidth;
            }
            if (silent || weight <= 0) {
                break;
            }
            const double centroid = moment / weight;
            if (settings.feature == Feature::centroid) {
                result = centroid;
            } else {
                double spread = 0;
                for (std::size_t k = low; k <= high; ++k) {
                    const double offset = static_cast<double>(k) * binWidth - centroid;
                    spread += current[k] * offset * offset;
                }
                result = std::sqrt(spread / weight);
            }
            break;
        }
        case Feature::rolloff: {
            double total = 0;
            for (std::size_t k = low; k <= high; ++k) {
                total += current[k] * current[k];
            }
            if (silent || total <= 0) {
                break;
            }
            double running = 0;
            result = static_cast<double>(high) * binWidth;
            for (std::size_t k = low; k <= high; ++k) {
                running += current[k] * current[k];
                if (running >= 0.85 * total) {
                    result = static_cast<double>(k) * binWidth;
                    break;
                }
            }
            break;
        }
        case Feature::flatness: {
            if (silent) {
                break;
            }
            double logSum = 0, sum = 0;
            for (std::size_t k = low; k <= high; ++k) {
                const double power = current[k] * current[k] + 1e-20;
                logSum += std::log(power);
                sum += power;
            }
            const double bandSize = static_cast<double>(high - low + 1);
            result = std::exp(logSum / bandSize) / (sum / bandSize);
            break;
        }
        case Feature::loudness:
            break;
        }
        values[firstHop + n] = result;
        if (settings.feature == Feature::flux) {
            std::swap_ranges(previous, previous + bins, current);
        }
    }
}

void featureLoudness(const AudioInput& input, const FeatureSettings& settings, std::size_t hopCount, double* values) noexcept {
    const std::size_t hop = featureHop(settings.sampleRate);
    const std::size_t frames = input.frames;
    // K-weighted energy of the hop-sized block around each frame centre: [h·hop − hop/2, h·hop + hop/2).
    std::vector<double> energy(hopCount, 0.0);
    for (std::size_t channel = 0; channel < input.channelCount; ++channel) {
        if (input.channels[channel] == nullptr) {
            continue;
        }
        const double weight = channel >= 3 ? 1.41 : 1.0;
        Biquad stageOne = shelf(settings.sampleRate), stageTwo = highPass(settings.sampleRate);
        for (std::size_t i = 0; i < frames; ++i) {
            const double raw = std::isfinite(input.channels[channel][i]) ? static_cast<double>(input.channels[channel][i]) : 0.0;
            const double weighted = stageTwo.step(stageOne.step(raw));
            const std::size_t block = std::min((i + hop / 2) / hop, hopCount - 1);
            energy[block] += weight * weighted * weighted;
        }
    }
    const std::size_t radius = std::max<std::size_t>(static_cast<std::size_t>(std::llround(0.2 * settings.sampleRate / static_cast<double>(hop))), 1);
    std::vector<double> prefix(hopCount + 1, 0.0);
    for (std::size_t h = 0; h < hopCount; ++h) {
        prefix[h + 1] = prefix[h] + energy[h];
    }
    for (std::size_t h = 0; h < hopCount; ++h) {
        const std::size_t from = h > radius ? h - radius : 0;
        const std::size_t to = std::min(hopCount, h + radius + 1);
        const double span = static_cast<double>((to - from) * hop);
        const double meanSquare = (prefix[to] - prefix[from]) / span;
        values[h] = meanSquare > 0 ? std::max(-0.691 + 10.0 * std::log10(meanSquare), -70.0) : -70.0;
    }
}

bool featureShape(double* values, std::size_t hopCount, const FeatureShape& shape) noexcept {
    if (values == nullptr || hopCount == 0) {
        return false;
    }
    std::size_t firstDefined = hopCount;
    for (std::size_t h = 0; h < hopCount; ++h) {
        if (std::isfinite(values[h])) {
            firstDefined = h;
            break;
        }
    }
    if (firstDefined == hopCount) {
        std::fill(values, values + hopCount, 0.0);
        return false;
    }
    double held = values[firstDefined];
    for (std::size_t h = 0; h < hopCount; ++h) {
        if (std::isfinite(values[h])) {
            held = values[h];
        } else {
            values[h] = held;
        }
    }
    double low = shape.minimum, high = shape.maximum;
    if (shape.autoRange) {
        std::vector<double> sorted(values, values + hopCount);
        std::sort(sorted.begin(), sorted.end());
        low = sorted[static_cast<std::size_t>(0.01 * static_cast<double>(hopCount - 1))];
        high = sorted[static_cast<std::size_t>(std::ceil(0.99 * static_cast<double>(hopCount - 1)))];
    }
    const double span = high - low;
    for (std::size_t h = 0; h < hopCount; ++h) {
        values[h] = span > 0 ? std::clamp((values[h] - low) / span, 0.0, 1.0) : 0.0;
    }
    if (shape.smoothMilliseconds > 0) {
        const double hopSeconds = static_cast<double>(featureHop(shape.sampleRate)) / shape.sampleRate;
        const double alpha = 1.0 - std::exp(-hopSeconds / (shape.smoothMilliseconds * 0.001));
        double state = values[0];
        for (std::size_t h = 0; h < hopCount; ++h) {
            state += alpha * (values[h] - state);
            values[h] = state;
        }
        state = values[hopCount - 1];
        for (std::size_t h = hopCount; h-- > 0;) {
            state += alpha * (values[h] - state);
            values[h] = state;
        }
    }
    return true;
}

void featureRender(const double* values, std::size_t hopCount, std::size_t hop, float* out, std::size_t frameOffset,
                   std::size_t count) noexcept {
    if (out == nullptr) {
        return;
    }
    if (values == nullptr || hopCount == 0 || hop == 0) {
        std::fill(out, out + count, 0.0f);
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const std::size_t index = frame / hop;
        const double fraction = static_cast<double>(frame % hop) / static_cast<double>(hop);
        const double a = values[std::min(index, hopCount - 1)];
        const double b = values[std::min(index + 1, hopCount - 1)];
        out[i] = static_cast<float>(a + (b - a) * fraction);
    }
}

} // namespace bake::dsp
