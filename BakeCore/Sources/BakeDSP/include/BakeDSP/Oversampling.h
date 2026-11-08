#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

// Offline oversampling for memoryless nonlinearities (Waveshaper, Wavefolder), and with
// `renderOversampledStateful` for shapers with memory (Derivative Distortion). The filter is a
// 64-taps-per-phase Kaiser-windowed sinc at the high rate, so 32x means a 2049-tap and 256x a 16,385-tap
// linear-phase filter on both the way up and the way down. That latency-free, long filter is what a realtime
// plugin cannot afford. Same algorithm and constants as Distortion's, so the two agree.

namespace bake::dsp {

/// 256x means a 16,385-tap linear-phase filter on both the way up and the way down. Offline, nothing else limits it.
inline constexpr int maxOversampling = 256;

inline int clampOversampling(int factor) noexcept { return std::clamp(factor, 1, maxOversampling); }

/// Scratch floats `renderOversampled` needs for chunks of up to `maxCount` frames.
inline std::size_t oversamplingScratchFloats(int factor, std::size_t maxCount) noexcept {
    const int clamped = clampOversampling(factor);
    if (clamped == 1) {
        return 1;
    }
    const std::size_t length = static_cast<std::size_t>(64 * clamped + 1);
    return (maxCount + 1) * clamped + 3 * length;
}

namespace oversampling {

inline long long floorDivide(long long value, long long divisor) noexcept {
    const long long quotient = value / divisor;
    return (value % divisor != 0 && value < 0) ? quotient - 1 : quotient;
}

inline double besselI0(double x) noexcept {
    double sum = 1, term = 1;
    for (int k = 1; k < 40; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
    }
    return sum;
}

/// Centered Kaiser-windowed sinc at the oversampled rate, unity DC gain.
inline void designTaps(int factor, float* taps) noexcept {
    constexpr double pi = 3.141592653589793;
    constexpr double cutoffFraction = 0.84; // of the base-rate Nyquist
    constexpr double kaiserBeta = 8.0;
    const int length = 64 * factor + 1;
    const int center = length / 2;
    double sum = 0;
    for (int k = 0; k < length; ++k) {
        const double t = static_cast<double>(k - center) / factor;
        const double x = pi * cutoffFraction * t;
        const double sinc = (k == center) ? 1.0 : std::sin(x) / x;
        const double r = static_cast<double>(k - center) / center;
        const double window = besselI0(kaiserBeta * std::sqrt(std::max(0.0, 1 - r * r))) / besselI0(kaiserBeta);
        taps[k] = static_cast<float>(sinc * window);
        sum += taps[k];
    }
    for (int k = 0; k < length; ++k) {
        taps[k] = static_cast<float>(taps[k] / sum);
    }
}

inline float inputAt(const float* input, std::size_t frames, long long index) noexcept {
    return (index < 0 || index >= static_cast<long long>(frames)) ? 0.0f : input[index];
}

} // namespace oversampling

/// Runs `shape(upsampled, frame)` (a memoryless function; `frame` is the base-rate frame whose
/// parameter values apply) at `factor` times the sample rate and writes the decimated result to
/// `output[0 … count)` for absolute frames `frameOffset …`. Stateless: output frame n depends only
/// on input frames within ±32 of n, read from the whole channel (`input` points at frame 0), so
/// chunking never changes the result. Frames outside [0, inputFrames) read as silence.
/// `factor` must be at least 2; `scratch` holds `oversamplingScratchFloats(factor, count)` floats.
template <class Shape>
void renderOversampled(int factor, const float* input, std::size_t inputFrames,
                       float* output, std::size_t frameOffset, std::size_t count,
                       float* scratch, Shape&& shape) noexcept {
    using namespace oversampling;
    if (input == nullptr || output == nullptr || scratch == nullptr || count == 0 || factor < 2) {
        return;
    }
    factor = clampOversampling(factor);
    const int length = 64 * factor + 1;
    const int center = length / 2;
    float* taps = scratch;
    float* high = scratch + length;
    designTaps(factor, taps);

    const long long firstHigh = static_cast<long long>(frameOffset) * factor - center;
    const long long highCount = static_cast<long long>(count - 1) * factor + 2 * center + 1;

    for (long long j = 0; j < highCount; ++j) {
        const long long m = firstHigh + j;
        // Interpolate: only every factor-th upsampled sample is non-zero (the input frames).
        const long long lowest = floorDivide(m + center - (length - 1) + factor - 1, factor);
        const long long highest = floorDivide(m + center, factor);
        double sum = 0;
        for (long long b = lowest; b <= highest; ++b) {
            sum += static_cast<double>(taps[m + center - b * factor]) * inputAt(input, inputFrames, b);
        }
        const float upsampled = static_cast<float>(sum * factor);
        const std::size_t frame = static_cast<std::size_t>(std::max<long long>(0, floorDivide(m, factor)));
        high[j] = shape(upsampled, frame);
    }

    for (std::size_t i = 0; i < count; ++i) {
        double sum = 0;
        const long long base = static_cast<long long>(i) * factor;
        for (int k = 0; k < length; ++k) {
            sum += static_cast<double>(taps[k]) * high[base + 2 * center - k];
        }
        output[i] = static_cast<float>(sum);
    }
}

/// Where a stateful oversampled stream has got to. One per channel, zero-initialised.
struct OversampledStream {
    long long nextHigh = 0; ///< absolute upsampled index of the next sample `shape` will see
    bool started = false;
};

/// Floats of decimator history one stream carries between calls.
inline std::size_t oversampledHistoryFloats(int factor) noexcept {
    return static_cast<std::size_t>(64 * clampOversampling(factor));
}

/// Like `renderOversampled`, for a `shape` with memory (integrators, filters): every upsampled sample
/// goes through `shape(upsampled, frame, state)` exactly once, in increasing order. The decimator's
/// overlap with the previous call comes from `history` (`oversampledHistoryFloats` floats), never from
/// a second pass through `shape`. Zero latency, as the upsampler reads the whole input channel.
/// Ranges must be consecutive across calls, starting at frame 0. Factor 1 calls `shape` on the input
/// frames directly (`scratch` and `history` are unused and may be null).
template <class State, class Shape>
void renderOversampledStateful(int factor, const float* input, std::size_t inputFrames,
                               float* output, std::size_t frameOffset, std::size_t count,
                               float* scratch, float* history, OversampledStream& stream,
                               State& state, Shape&& shape) noexcept {
    using namespace oversampling;
    if (input == nullptr || output == nullptr || count == 0) {
        return;
    }
    if (factor < 2) {
        for (std::size_t i = 0; i < count; ++i) {
            const std::size_t frame = frameOffset + i;
            output[i] = shape(inputAt(input, inputFrames, static_cast<long long>(frame)), frame, state);
        }
        return;
    }
    if (scratch == nullptr || history == nullptr) {
        return;
    }
    factor = clampOversampling(factor);
    const int length = 64 * factor + 1;
    const int center = length / 2;
    const long long kept = 2LL * center; // == oversampledHistoryFloats(factor)
    float* taps = scratch;
    float* high = scratch + length;
    designTaps(factor, taps);

    const long long firstHigh = static_cast<long long>(frameOffset) * factor - center;
    const long long highCount = static_cast<long long>(count - 1) * factor + 2 * center + 1;
    // Consecutive chunks overlap by 2·center + 1 − factor upsampled samples (< kept): reuse them.
    long long reused = 0;
    if (stream.started) {
        reused = std::clamp<long long>(stream.nextHigh - firstHigh, 0, std::min(highCount, kept));
        for (long long j = 0; j < reused; ++j) {
            high[j] = history[kept - reused + j];
        }
    }
    for (long long j = reused; j < highCount; ++j) {
        const long long m = firstHigh + j;
        const long long lowest = floorDivide(m + center - (length - 1) + factor - 1, factor);
        const long long highest = floorDivide(m + center, factor);
        double sum = 0;
        for (long long b = lowest; b <= highest; ++b) {
            sum += static_cast<double>(taps[m + center - b * factor]) * inputAt(input, inputFrames, b);
        }
        const std::size_t frame = static_cast<std::size_t>(std::max<long long>(0, floorDivide(m, factor)));
        high[j] = shape(static_cast<float>(sum * factor), frame, state);
    }
    for (long long j = 0; j < kept; ++j) {
        history[j] = high[highCount - kept + j];
    }
    stream.nextHigh = firstHigh + highCount;
    stream.started = true;

    for (std::size_t i = 0; i < count; ++i) {
        double sum = 0;
        const long long base = static_cast<long long>(i) * factor;
        for (int k = 0; k < length; ++k) {
            sum += static_cast<double>(taps[k]) * high[base + 2 * center - k];
        }
        output[i] = static_cast<float>(sum);
    }
}

} // namespace bake::dsp
