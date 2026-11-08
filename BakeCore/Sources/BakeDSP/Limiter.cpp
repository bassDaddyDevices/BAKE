#include "BakeDSP/Limiter.h"

#include <algorithm>
#include <cmath>
#include <deque>

#include "BakeDSP/Oversampling.h"

namespace bake::dsp {
namespace {

constexpr double dbToNeper = 0.11512925464970229;   // ln(10) / 20

double settle(double ms, double sampleRate) noexcept {
    const double frames = ms * 0.001 * sampleRate;
    return frames < 1.0 ? 0.0 : std::pow(0.1, 1.0 / frames);
}

} // namespace

std::size_t limiterTapCount(int factor) noexcept {
    return static_cast<std::size_t>(64 * clampOversampling(factor) + 1);
}

void limiterDesign(int factor, float* taps) noexcept {
    if (taps != nullptr && factor >= 2) {
        oversampling::designTaps(clampOversampling(factor), taps);
    }
}

static void peaksOf(const AudioInput& input, std::size_t firstChannel, std::size_t endChannel, int factor, const float* taps,
                    std::size_t firstFrame, std::size_t count, float* peaks) noexcept {
    if (peaks == nullptr) {
        return;
    }
    factor = clampOversampling(factor);
    const long long length = static_cast<long long>(64) * factor + 1;
    const long long center = length / 2;
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = firstFrame + i;
        double peak = 0;
        for (std::size_t channel = firstChannel; channel < endChannel; ++channel) {
            const double here = std::abs(static_cast<double>(input.sample(channel, frame)));
            peak = std::max(peak, std::isfinite(here) ? here : 0.0);
            if (factor < 2 || taps == nullptr) {
                continue;
            }
            // The in-between samples of this frame and the next.
            for (int phase = 1; phase < factor; ++phase) {
                const long long m = static_cast<long long>(frame) * factor + phase;
                const long long lowest = oversampling::floorDivide(m + center - (length - 1) + factor - 1, factor);
                const long long highest = oversampling::floorDivide(m + center, factor);
                double sum = 0;
                for (long long b = lowest; b <= highest; ++b) {
                    if (b < 0 || b >= static_cast<long long>(input.frames)) {
                        continue;
                    }
                    sum += static_cast<double>(taps[m + center - b * factor]) * input.sample(channel, static_cast<std::size_t>(b));
                }
                peak = std::max(peak, std::abs(sum * factor));
            }
        }
        peaks[i] = static_cast<float>(peak);
    }
}

void limiterPeaks(const AudioInput& input, int factor, const float* taps, std::size_t firstFrame, std::size_t count,
                  float* peaks) noexcept {
    peaksOf(input, 0, input.channelCount, factor, taps, firstFrame, count, peaks);
}

void limiterChannelPeaks(const AudioInput& input, std::size_t channel, int factor, const float* taps,
                         std::size_t firstFrame, std::size_t count, float* peaks) noexcept {
    if (channel < input.channelCount) {
        peaksOf(input, channel, channel + 1, factor, taps, firstFrame, count, peaks);
    } else if (peaks != nullptr) {
        std::fill(peaks, peaks + count, 0.0f);
    }
}

void limiterNeeded(const float* peaks, std::size_t frames, const ParameterSignal& gain, const LimiterSettings& settings,
                   float* neededDb) noexcept {
    if (peaks == nullptr || neededDb == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < frames; ++i) {
        const double level = static_cast<double>(peaks[i]) * std::exp(static_cast<double>(gain.valueAt(i)) * dbToNeper);
        const double over = level <= 1e-9 ? -1000.0 : 20.0 * std::log10(level) - settings.ceilingDb;
        neededDb[i] = static_cast<float>(std::clamp(over, 0.0, limiterMaxReductionDb));
    }
}

void limiterLink(float* const* neededDb, int channelCount, std::size_t frames, double link) noexcept {
    if (neededDb == nullptr || channelCount < 2 || link <= 0) {
        return;
    }
    const float amount = static_cast<float>(std::min(link, 1.0));
    for (std::size_t i = 0; i < frames; ++i) {
        float largest = neededDb[0][i];
        for (int c = 1; c < channelCount; ++c) {
            largest = std::max(largest, neededDb[c][i]);
        }
        for (int c = 0; c < channelCount; ++c) {
            neededDb[c][i] += amount * (largest - neededDb[c][i]);
        }
    }
}

void limiterCurve(float* neededDb, std::size_t frames, const LimiterSettings& settings, float* reductionDb) noexcept {
    if (neededDb == nullptr || reductionDb == nullptr || frames == 0) {
        return;
    }
    // Hold: each need is kept for the hold time (the largest need of the last `hold` frames), before Release can start.
    const long long holdFrames = static_cast<long long>(settings.holdMs * 0.001 * settings.sampleRate);
    std::vector<float> needed(neededDb, neededDb + frames);
    if (holdFrames > 0) {
        std::deque<std::size_t> queue;
        for (std::size_t i = 0; i < frames; ++i) {
            while (!queue.empty() && neededDb[queue.back()] <= neededDb[i]) {
                queue.pop_back();
            }
            queue.push_back(i);
            while (static_cast<long long>(i - queue.front()) > holdFrames) {
                queue.pop_front();
            }
            needed[i] = neededDb[queue.front()];
        }
    }
    // The least curve that is never under what is needed, never falls faster than Release and never rises faster than
    // Look-ahead: the best of every peak's decay to the right (Release) and to the left (Look-ahead).
    const double ahead = settle(settings.lookaheadMs, settings.sampleRate);
    const double back = settle(settings.releaseMs, settings.sampleRate);
    std::vector<float> early(frames);
    double carried = 0;
    for (std::size_t i = frames; i-- > 0;) {
        carried = std::max(static_cast<double>(neededDb[i]), carried * ahead);
        early[i] = static_cast<float>(carried);
    }
    carried = 0;
    for (std::size_t i = 0; i < frames; ++i) {
        carried = std::max(static_cast<double>(needed[i]), carried * back);
        reductionDb[i] = std::max(early[i], static_cast<float>(carried));
    }
    // Round the corner at each peak: widen every value by half a window, then average over the window. The result is
    // never under the curve it started from.
    const long long window = static_cast<long long>(0.0005 * settings.sampleRate);
    if (window < 2) {
        return;
    }
    const long long radius = window / 2;
    const long long n = static_cast<long long>(frames);
    std::vector<float> widened(frames);
    std::deque<long long> queue;
    long long next = 0;
    for (long long i = 0; i < n; ++i) {
        const long long hi = std::min(n - 1, i + radius);
        while (next <= hi) {
            while (!queue.empty() && reductionDb[queue.back()] <= reductionDb[next]) {
                queue.pop_back();
            }
            queue.push_back(next++);
        }
        while (queue.front() < i - radius) {
            queue.pop_front();
        }
        widened[static_cast<std::size_t>(i)] = reductionDb[queue.front()];
    }
    std::vector<double> prefix(frames + 1, 0.0);
    for (std::size_t i = 0; i < frames; ++i) {
        prefix[i + 1] = prefix[i] + widened[i];
    }
    for (long long i = 0; i < n; ++i) {
        const long long lo = std::max<long long>(i - radius, 0);
        const long long hi = std::min<long long>(i + radius + 1, n);
        // Past the ends the widened curve holds its edge value.
        const double edge = static_cast<double>((i - radius) < 0 ? radius - i : 0) * widened[0]
            + static_cast<double>((i + radius + 1) > n ? (i + radius + 1 - n) : 0) * widened[frames - 1];
        const double mean = (prefix[static_cast<std::size_t>(hi)] - prefix[static_cast<std::size_t>(lo)] + edge)
            / static_cast<double>(2 * radius + 1);
        reductionDb[i] = std::max(static_cast<float>(mean), neededDb[static_cast<std::size_t>(i)]);
    }
}

void limiterSolve(const float* peaks, std::size_t frames, const ParameterSignal& gain, const LimiterSettings& settings,
                  float* reductionDb) noexcept {
    if (peaks == nullptr || reductionDb == nullptr || frames == 0) {
        return;
    }
    std::vector<float> needed(frames);
    limiterNeeded(peaks, frames, gain, settings, needed.data());
    limiterCurve(needed.data(), frames, settings, reductionDb);
}

void limiterRender(const AudioInput& input, const float* reductionDb, const ParameterSignal& gain, float* const* outputs,
                   int channelCount, std::size_t frameOffset, std::size_t count) noexcept {
    if (outputs == nullptr) {
        return;
    }
    for (int channel = 0; channel < channelCount; ++channel) {
        float* out = outputs[channel];
        if (out == nullptr) {
            continue;
        }
        for (std::size_t i = 0; i < count; ++i) {
            const std::size_t frame = frameOffset + i;
            const double decibels = static_cast<double>(gain.valueAt(frame)) - (reductionDb != nullptr ? static_cast<double>(reductionDb[frame]) : 0.0);
            out[i] = static_cast<float>(static_cast<double>(input.sample(static_cast<std::size_t>(channel), frame)) * std::exp(decibels * dbToNeper));
        }
    }
}

void limiterRenderChannel(const AudioInput& input, std::size_t channel, const float* reductionDb, const ParameterSignal& gain,
                          float* out, std::size_t frameOffset, std::size_t count) noexcept {
    if (out == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double decibels = static_cast<double>(gain.valueAt(frame)) - (reductionDb != nullptr ? static_cast<double>(reductionDb[frame]) : 0.0);
        out[i] = static_cast<float>(static_cast<double>(input.sample(channel, frame)) * std::exp(decibels * dbToNeper));
    }
}

} // namespace bake::dsp
