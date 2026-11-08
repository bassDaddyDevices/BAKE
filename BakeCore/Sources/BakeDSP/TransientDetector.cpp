#include "BakeDSP/TransientDetector.h"

#include <algorithm>
#include <cmath>
#include <deque>
#include <vector>

#include "BakeDSP/Fft.h"

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

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

struct Band {
    std::size_t low, high;
};

Band bandOf(const TransientSettings& settings, std::size_t size) noexcept {
    const double binWidth = settings.sampleRate / static_cast<double>(size);
    const std::size_t top = size / 2;
    std::size_t low = static_cast<std::size_t>(std::max(std::ceil(settings.lowCut / binWidth), 1.0));
    std::size_t high = static_cast<std::size_t>(std::max(std::floor(settings.highCut / binWidth), 1.0));
    low = std::min(low, top);
    high = std::min(std::max(high, low), top);
    return {low, high};
}

/// Slides a window of ±`radius` over `values`, calling `emit(i, extreme)`; `greater` selects max or min.
template <typename Compare>
void slidingExtreme(const std::vector<double>& values, std::size_t radius, Compare better, std::vector<double>& out) {
    const std::size_t n = values.size();
    out.assign(n, 0.0);
    std::deque<std::size_t> window;
    std::size_t next = 0;
    for (std::size_t i = 0; i < n; ++i) {
        const std::size_t hi = std::min(n - 1, i + radius);
        while (next <= hi) {
            while (!window.empty() && !better(values[window.back()], values[next])) {
                window.pop_back();
            }
            window.push_back(next++);
        }
        const std::size_t lo = i > radius ? i - radius : 0;
        while (window.front() < lo) {
            window.pop_front();
        }
        out[i] = values[window.front()];
    }
}

} // namespace

std::size_t transientFrameSize(double sampleRate) noexcept {
    return nextPowerOfTwo(static_cast<std::size_t>(std::max(sampleRate, 8000.0) * 0.0213));
}

std::size_t transientHop(double sampleRate) noexcept {
    return transientFrameSize(sampleRate) / 4;
}

std::size_t transientHopCount(std::size_t frames, double sampleRate) noexcept {
    return frames / transientHop(sampleRate) + 2;
}

std::size_t transientScratchDoubles(double sampleRate) noexcept {
    return transientFrameSize(sampleRate) * 6 + 8;
}

void transientDetection(const AudioInput& input, const TransientSettings& settings, std::size_t firstHop,
                        std::size_t count, double* scratch, double* detection) noexcept {
    const std::size_t size = transientFrameSize(settings.sampleRate);
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
    const Band band = bandOf(settings, size);
    const double scale = 1.0 / static_cast<double>(size);

    auto magnitudes = [&](std::size_t h, double* out) {
        const long long start = static_cast<long long>(h * hop) - static_cast<long long>(size / 2);
        for (std::size_t i = 0; i < size; ++i) {
            const long long frame = start + static_cast<long long>(i);
            real[i] = frame < 0 ? 0.0 : window[i] * mono(input, static_cast<std::size_t>(frame));
            imaginary[i] = 0.0;
        }
        fft(real, imaginary, size, cosines, sines);
        for (std::size_t k = 0; k < bins; ++k) {
            out[k] = std::sqrt(real[k] * real[k] + imaginary[k] * imaginary[k]) * scale;
        }
    };
    auto level = [&](const double* mags) {
        double sum = 0;
        for (std::size_t k = band.low; k <= band.high; ++k) {
            const double power = mags[k] * mags[k];
            sum += settings.mode == TransientMode::highFrequency ? static_cast<double>(k) * power : power;
        }
        return std::log(sum + 1e-10);
    };

    // The frame before the range, for the first difference (silence before the file starts).
    if (firstHop == 0) {
        std::fill(previous, previous + bins, 0.0);
    } else {
        magnitudes(firstHop - 1, previous);
    }
    for (std::size_t n = 0; n < count; ++n) {
        magnitudes(firstHop + n, current);
        double rise = 0;
        if (settings.mode == TransientMode::spectralFlux) {
            for (std::size_t k = band.low; k <= band.high; ++k) {
                rise += std::max(0.0, std::log1p(1000.0 * current[k]) - std::log1p(1000.0 * previous[k]));
            }
        } else {
            rise = std::max(0.0, level(current) - level(previous));
        }
        detection[firstHop + n] = rise;
        std::swap_ranges(previous, previous + bins, current);
    }
}

std::size_t transientMaxOnsets(std::size_t frames, double minGapMilliseconds, double sampleRate) noexcept {
    const std::size_t gap = std::max<std::size_t>(static_cast<std::size_t>(minGapMilliseconds * 0.001 * sampleRate), 1);
    return frames / gap + 2;
}

std::size_t transientPick(const AudioInput& input, const TransientSettings& settings, const double* detection,
                          std::size_t hopCount, std::size_t* onsets, float* strengths, std::size_t capacity) noexcept {
    if (detection == nullptr || hopCount < 3 || capacity == 0 || onsets == nullptr || strengths == nullptr) {
        return 0;
    }
    const std::size_t size = transientFrameSize(settings.sampleRate);
    const std::size_t hop = size / 4;
    const double hopSeconds = static_cast<double>(hop) / settings.sampleRate;
    const std::vector<double> d(detection, detection + hopCount);
    const double sensitivity = std::clamp(settings.sensitivity, 0.0, 1.0);

    // Local mean (±0.2 s) from prefix sums, local maximum (±1 s) from a sliding window.
    std::vector<double> prefix(hopCount + 1, 0.0);
    for (std::size_t i = 0; i < hopCount; ++i) prefix[i + 1] = prefix[i] + d[i];
    const std::size_t meanRadius = std::max<std::size_t>(static_cast<std::size_t>(0.2 / hopSeconds), 1);
    const std::size_t maxRadius = std::max<std::size_t>(static_cast<std::size_t>(1.0 / hopSeconds), 1);
    std::vector<double> localMax;
    slidingExtreme(d, maxRadius, [](double a, double b) { return a > b; }, localMax);
    const double globalMax = *std::max_element(d.begin(), d.end());
    if (globalMax <= 0) {
        return 0;
    }
    const std::size_t gapFrames = std::max<std::size_t>(static_cast<std::size_t>(settings.minGapMilliseconds * 0.001 * settings.sampleRate), 1);
    struct Candidate { std::size_t hop; double rise; };
    std::vector<Candidate> candidates;
    for (std::size_t h = 1; h + 1 < hopCount; ++h) {
        const std::size_t lo = h > meanRadius ? h - meanRadius : 0;
        const std::size_t hi = std::min(hopCount, h + meanRadius + 1);
        const double mean = (prefix[hi] - prefix[lo]) / static_cast<double>(hi - lo);
        const double reach = std::max(localMax[h], 0.25 * globalMax);
        const double threshold = mean + (0.05 + 0.5 * (1.0 - sensitivity)) * reach;
        if (d[h] > threshold && d[h] >= d[h - 1] && d[h] > d[h + 1] ) {
            candidates.push_back({h, d[h]});
        }
    }

    // The minimum gap, strongest first: a weaker peak survives unless a stronger one already kept is within the gap.
    {
        std::vector<std::size_t> order(candidates.size());
        for (std::size_t i = 0; i < order.size(); ++i) order[i] = i;
        std::stable_sort(order.begin(), order.end(), [&](std::size_t a, std::size_t b) { return candidates[a].rise > candidates[b].rise; });
        const std::size_t gapHops = std::max<std::size_t>(gapFrames / hop, 1);
        std::vector<std::size_t> accepted;   // hop numbers, kept sorted
        std::vector<char> keep(candidates.size(), 0);
        for (std::size_t index : order) {
            const std::size_t h = candidates[index].hop;
            auto next = std::lower_bound(accepted.begin(), accepted.end(), h);
            const bool nearNext = next != accepted.end() && *next - h < gapHops;
            const bool nearPrevious = next != accepted.begin() && h - *(next - 1) < gapHops;
            if (!nearNext && !nearPrevious) {
                accepted.insert(next, h);
                keep[index] = 1;
            }
        }
        std::vector<Candidate> survivors;
        for (std::size_t i = 0; i < candidates.size(); ++i) if (keep[i]) survivors.push_back(candidates[i]);
        candidates = std::move(survivors);
    }

    // Where each onset sits: the detection frame's new audio, or (Back-track) the start of its attack.
    const std::size_t frames = input.frames;
    const std::size_t block = std::max<std::size_t>(static_cast<std::size_t>(settings.sampleRate * 0.0007), 4);
    struct Onset { std::size_t frame; double rise; };
    std::vector<Onset> placed;
    for (const Candidate& candidate : candidates) {
        long long center = static_cast<long long>(candidate.hop * hop) + static_cast<long long>(size / 2) - static_cast<long long>(hop / 2);
        center = std::clamp<long long>(center, 0, static_cast<long long>(frames) - 1);
        std::size_t position = static_cast<std::size_t>(center);
        if (settings.backTrack && frames > 0) {
            const long long searchLow = std::max<long long>(center - static_cast<long long>(size / 2 + hop), 0);
            const long long searchHigh = std::min<long long>(center + static_cast<long long>(size / 2), static_cast<long long>(frames) - 1);
            const std::size_t first = static_cast<std::size_t>(searchLow) / block;
            const std::size_t last = static_cast<std::size_t>(searchHigh) / block;
            std::vector<double> energy;
            for (std::size_t b = first; b <= last; ++b) {
                double sum = 0;
                for (std::size_t i = b * block; i < std::min((b + 1) * block, frames); ++i) {
                    const double value = mono(input, i);
                    sum += value * value;
                }
                energy.push_back(std::sqrt(sum / static_cast<double>(block)));
            }
            // The loudest block from just before the estimate to a little after it.
            const std::size_t peakFrom = static_cast<std::size_t>(std::max<long long>(center - static_cast<long long>(hop), searchLow)) / block - first;
            std::size_t peak = peakFrom;
            for (std::size_t b = peakFrom; b < energy.size(); ++b) {
                if (energy[b] > energy[peak]) peak = b;
            }
            if (energy[peak] > 0) {
                // Back from the peak to the last block still quiet next to it; failing that, the quietest block.
                long long quiet = -1;
                for (long long b = static_cast<long long>(peak); b >= 0; --b) {
                    if (energy[static_cast<std::size_t>(b)] < 0.1 * energy[peak]) { quiet = b; break; }
                }
                std::size_t start;
                if (quiet >= 0) {
                    start = (first + static_cast<std::size_t>(quiet) + 1) * block;
                } else {
                    std::size_t least = 0;
                    for (std::size_t b = 0; b <= peak; ++b) if (energy[b] < energy[least]) least = b;
                    start = (first + least) * block;
                }
                position = std::min(start, static_cast<std::size_t>(center));
            }
        }
        placed.push_back({position, candidate.rise});
    }

    // The minimum gap between where the onsets finally sit: of two too close, the stronger stays.
    std::vector<Onset> kept;
    for (const Onset& onset : placed) {
        if (!kept.empty() && onset.frame < kept.back().frame + gapFrames) {
            if (onset.rise > kept.back().rise) {
                if (kept.size() < 2 || onset.frame >= kept[kept.size() - 2].frame + gapFrames) {
                    kept.back() = onset;
                }
            }
            continue;
        }
        kept.push_back(onset);
    }
    double strongest = 0;
    for (const Onset& onset : kept) strongest = std::max(strongest, onset.rise);
    const std::size_t count = std::min(kept.size(), capacity);
    for (std::size_t i = 0; i < count; ++i) {
        onsets[i] = kept[i].frame;
        strengths[i] = strongest > 0 ? static_cast<float>(std::clamp(kept[i].rise / strongest, 0.0, 1.0)) : 0.0f;
    }
    return count;
}

void transientRender(const std::size_t* onsets, const float* strengths, std::size_t onsetCount, std::size_t pulseFrames,
                     float* bang, float* strength, std::size_t frameOffset, std::size_t count) noexcept {
    if (onsetCount == 0 || onsets == nullptr) {
        for (std::size_t i = 0; i < count; ++i) {
            if (bang) bang[i] = 0;
            if (strength) strength[i] = 0;
        }
        return;
    }
    // The first onset at or before the chunk's first frame, then forward in step with the frames.
    std::size_t index = static_cast<std::size_t>(std::upper_bound(onsets, onsets + onsetCount, frameOffset) - onsets);
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        while (index < onsetCount && onsets[index] <= frame) {
            ++index;
        }
        if (index == 0) {
            if (bang) bang[i] = 0;
            if (strength) strength[i] = 0;
            continue;
        }
        const std::size_t current = index - 1;
        std::size_t length = std::max<std::size_t>(pulseFrames, 1);
        if (current + 1 < onsetCount) {
            length = std::min(length, std::max<std::size_t>(onsets[current + 1] - onsets[current] - 1, 1));
        }
        if (bang) bang[i] = frame - onsets[current] < length ? 1.0f : 0.0f;
        if (strength) strength[i] = strengths[current];
    }
}

} // namespace bake::dsp
