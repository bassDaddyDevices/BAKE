#include "BakeDSP/Analysis.h"
#include "BakeDSP/Fft.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

float sampleAt(const float* const* channels, std::size_t channel, std::size_t frame) noexcept {
    const float value = channels[channel] == nullptr ? 0.0f : channels[channel][frame];
    return std::isfinite(value) ? value : 0.0f;
}

} // namespace

void summarizeEnvelope(const float* const* channels, std::size_t channelCount, std::size_t frames, std::size_t buckets,
                       float* minimums, float* maximums, float* rms) noexcept {
    if (channels == nullptr || minimums == nullptr || maximums == nullptr || rms == nullptr || buckets == 0) {
        return;
    }
    for (std::size_t bucket = 0; bucket < buckets; ++bucket) {
        const std::size_t first = bucket * frames / buckets;
        const std::size_t last = std::max((bucket + 1) * frames / buckets, first + 1);
        float low = 0.0f, high = 0.0f;
        double energy = 0.0;
        std::size_t count = 0;
        for (std::size_t frame = first; frame < last && frame < frames; ++frame) {
            for (std::size_t channel = 0; channel < channelCount; ++channel) {
                const float value = sampleAt(channels, channel, frame);
                low = std::min(low, value);
                high = std::max(high, value);
                energy += static_cast<double>(value) * value;
                ++count;
            }
        }
        minimums[bucket] = low;
        maximums[bucket] = high;
        rms[bucket] = count == 0 ? 0.0f : static_cast<float>(std::sqrt(energy / count));
    }
}

void analyzeSpectrogram(const float* const* channels, std::size_t channelCount, std::size_t frames, double sampleRate,
                        std::size_t columns, std::size_t rows, std::uint8_t* output, double* scratch) noexcept {
    if (channels == nullptr || output == nullptr || scratch == nullptr || columns == 0 || rows == 0 || !(sampleRate > 0)) {
        return;
    }
    const std::size_t size = spectrogramWindow;
    double* window = scratch;
    double* real = scratch + size;
    double* imaginary = scratch + 2 * size;
    double* cosines = scratch + 3 * size;
    double* sines = cosines + size / 2;
    for (std::size_t i = 0; i < size; ++i) {
        window[i] = 0.5 - 0.5 * std::cos(2.0 * pi * static_cast<double>(i) / static_cast<double>(size));
    }
    fftTwiddles(size, cosines, sines);

    const double binHz = sampleRate / static_cast<double>(size);
    const double highest = std::min(20000.0, 0.45 * sampleRate);
    const double ratio = highest / spectrogramLowestHz;
    const double scale = 4.0 / static_cast<double>(size); // a full-scale sine reads 1.0 under a Hann window
    const double invChannels = channelCount == 0 ? 0.0 : 1.0 / static_cast<double>(channelCount);

    for (std::size_t column = 0; column < columns; ++column) {
        const long long centre = static_cast<long long>((static_cast<double>(column) + 0.5) * static_cast<double>(frames) / static_cast<double>(columns));
        for (std::size_t i = 0; i < size; ++i) {
            const long long frame = centre - static_cast<long long>(size / 2) + static_cast<long long>(i);
            double sum = 0.0;
            if (frame >= 0 && frame < static_cast<long long>(frames)) {
                for (std::size_t channel = 0; channel < channelCount; ++channel) {
                    sum += sampleAt(channels, channel, static_cast<std::size_t>(frame));
                }
            }
            real[i] = sum * invChannels * window[i];
            imaginary[i] = 0.0;
        }
        fft(real, imaginary, size, cosines, sines);

        auto magnitude = [&](std::size_t bin) { return std::sqrt(real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) * scale; };
        for (std::size_t row = 0; row < rows; ++row) {
            const double low = spectrogramLowestHz * std::pow(ratio, static_cast<double>(row) / static_cast<double>(rows));
            const double high = spectrogramLowestHz * std::pow(ratio, static_cast<double>(row + 1) / static_cast<double>(rows));
            const long long firstBin = static_cast<long long>(std::ceil(low / binHz));
            const long long lastBin = std::min(static_cast<long long>(std::floor(high / binHz)), static_cast<long long>(size / 2 - 1));
            double loudest = 0.0;
            if (lastBin >= firstBin) {
                for (long long bin = std::max<long long>(firstBin, 1); bin <= lastBin; ++bin) {
                    loudest = std::max(loudest, magnitude(static_cast<std::size_t>(bin)));
                }
            } else {
                // The band falls between two bins (the lowest rows): read the spectrum between them.
                const double position = std::sqrt(low * high) / binHz;
                const std::size_t below = std::min(static_cast<std::size_t>(std::max(position, 0.0)), size / 2 - 2);
                const double fraction = std::clamp(position - static_cast<double>(below), 0.0, 1.0);
                loudest = (1.0 - fraction) * magnitude(below) + fraction * magnitude(below + 1);
            }
            const double decibels = 20.0 * std::log10(loudest + 1e-9);
            const double level = std::clamp((decibels - spectrogramFloorDecibels) / -spectrogramFloorDecibels, 0.0, 1.0);
            output[row * columns + column] = static_cast<std::uint8_t>(std::lround(level * 255.0));
        }
    }
}

} // namespace bake::dsp
