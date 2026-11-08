#include "BakeDSP/LinearPhase.h"

#include <algorithm>
#include <cmath>

#include "BakeDSP/Fft.h"

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;
constexpr double kaiserBeta = 10.0;   // about 100 dB of stopband

double besselI0(double x) noexcept {
    double sum = 1, term = 1;
    for (int k = 1; k < 60; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        if (term < 1e-18 * sum) {
            break;
        }
    }
    return sum;
}

int reach(int taps) noexcept { return (linearPhaseTaps(taps) - 1) / 2; }

/// FFT length for fixed-kernel blocks, and the frames each block yields.
std::size_t staticTransformSize(int taps) noexcept {
    const std::size_t m = static_cast<std::size_t>(reach(taps));
    return nextPowerOfTwo(std::max<std::size_t>(8192, 4 * m));
}

std::size_t modulatedTransformSize(int taps) noexcept {
    const std::size_t m = static_cast<std::size_t>(reach(taps));
    return nextPowerOfTwo(2 * linearPhaseHop(taps) + 2 * m);
}

/// Adds `gain` x (a unity-DC-gain windowed-sinc low-pass at `cutoffHz`) to `kernel`.
void addLowpass(double* kernel, int taps, double cutoffHz, double sampleRate, const double* window, double gain) noexcept {
    const int centre = (taps - 1) / 2;
    const double normalised = 2.0 * cutoffHz / sampleRate;   // cycles per sample, doubled
    auto tap = [&](int i) {
        const double n = static_cast<double>(i - centre);
        const double x = pi * normalised * n;
        return (n == 0.0 ? normalised : normalised * std::sin(x) / x) * window[i];
    };
    double sum = 0.0;
    for (int i = 0; i < taps; ++i) {
        sum += tap(i);
    }
    const double scale = sum != 0.0 ? gain / sum : 0.0;
    for (int i = 0; i < taps; ++i) {
        kernel[i] += tap(i) * scale;
    }
}

/// The filter's input after Drive, as the biquad filter applies it.
double shapedInput(const float* input, std::size_t inputFrames, long long frame, const ParameterSignal& drive) noexcept {
    if (frame < 0 || frame >= static_cast<long long>(inputFrames)) {
        return 0.0;
    }
    double x = std::isfinite(input[frame]) ? input[frame] : 0.0f;
    const float driveDecibels = drive.valueAt(static_cast<std::size_t>(frame));
    if (driveDecibels > 0) {
        const double gain = std::pow(10.0, driveDecibels / 20.0);
        x += (std::tanh(gain * x) - x) * (driveDecibels / drive.maximum);
    }
    return x;
}

struct Workspace {
    std::size_t size = 0;
    int taps = 0;
    const double* cosines = nullptr;
    const double* sines = nullptr;
    double* kernelReal = nullptr;
    double* kernelImaginary = nullptr;
    double* segmentReal = nullptr;
    double* segmentImaginary = nullptr;
    double* kernelTime = nullptr;
    const double* window = nullptr;
};

Workspace carve(int requestedTaps, std::size_t size, double* scratch) noexcept {
    Workspace w;
    w.size = size;
    w.taps = linearPhaseTaps(requestedTaps);
    double* at = scratch;
    double* cosines = at; at += size / 2;
    double* sines = at; at += size / 2;
    w.cosines = cosines;
    w.sines = sines;
    w.kernelReal = at; at += size;
    w.kernelImaginary = at; at += size;
    w.segmentReal = at; at += size;
    w.segmentImaginary = at; at += size;
    w.kernelTime = at; at += size;
    double* window = at;
    w.window = window;
    return w;
}

/// Transforms the kernel for (type, cutoff, q) into the workspace's kernel spectrum.
void prepareKernel(Workspace& w, FilterType type, double cutoff, double q, double sampleRate) noexcept {
    designLinearPhaseKernel(type, cutoff, q, w.taps, sampleRate, w.window, w.kernelTime);
    std::fill(w.kernelReal, w.kernelReal + w.size, 0.0);
    std::fill(w.kernelImaginary, w.kernelImaginary + w.size, 0.0);
    std::copy(w.kernelTime, w.kernelTime + w.taps, w.kernelReal);
    fft(w.kernelReal, w.kernelImaginary, w.size, w.cosines, w.sines);
}

/// out[0 … count) = the centred filtered signal at frames first … first + count. `count` must not exceed size - 2·reach.
void convolve(Workspace& w, const float* input, std::size_t inputFrames, const ParameterSignal& drive,
              long long first, std::size_t count, double* out) noexcept {
    const long long m = (w.taps - 1) / 2;
    const long long start = first - m;
    for (std::size_t i = 0; i < w.size; ++i) {
        w.segmentReal[i] = shapedInput(input, inputFrames, start + static_cast<long long>(i), drive);
        w.segmentImaginary[i] = 0.0;
    }
    fft(w.segmentReal, w.segmentImaginary, w.size, w.cosines, w.sines);
    for (std::size_t i = 0; i < w.size; ++i) {
        const double re = w.segmentReal[i] * w.kernelReal[i] - w.segmentImaginary[i] * w.kernelImaginary[i];
        const double im = w.segmentReal[i] * w.kernelImaginary[i] + w.segmentImaginary[i] * w.kernelReal[i];
        w.segmentReal[i] = re;
        w.segmentImaginary[i] = im;
    }
    inverseFft(w.segmentReal, w.segmentImaginary, w.size, w.cosines, w.sines);
    for (std::size_t i = 0; i < count; ++i) {
        out[i] = w.segmentReal[2 * static_cast<std::size_t>(m) + i];
    }
}

} // namespace

int linearPhaseTaps(int requested) noexcept {
    const int clamped = std::clamp(requested, minimumLinearPhaseTaps, maximumLinearPhaseTaps);
    return clamped | 1;
}

double linearPhaseTransitionHz(int taps, double sampleRate) noexcept {
    const double omega = (linearPhaseStopbandDecibels - 7.95) / (2.285 * (linearPhaseTaps(taps) - 1));
    return 0.68 * omega / (2.0 * pi) * sampleRate;
}

std::size_t linearPhaseHop(int taps) noexcept {
    return std::max<std::size_t>(1024, static_cast<std::size_t>(linearPhaseTaps(taps)) / 4);
}

std::size_t linearPhaseScratchDoubles(int taps, bool modulated) noexcept {
    const std::size_t size = modulated ? modulatedTransformSize(taps) : staticTransformSize(taps);
    // Laid out as: twiddles, kernel spectrum (2), segment (2), kernel in time, window, and two blocks of
    // output for the cross-fade (2): nine transform lengths in all.
    return 9 * size;
}

void kaiserWindow(int taps, double* window) noexcept {
    const int count = linearPhaseTaps(taps);
    const double centre = (count - 1) / 2.0;
    const double denominator = besselI0(kaiserBeta);
    for (int i = 0; i < count; ++i) {
        const double r = (static_cast<double>(i) - centre) / centre;
        window[i] = besselI0(kaiserBeta * std::sqrt(std::max(0.0, 1.0 - r * r))) / denominator;
    }
}

void designLinearPhaseKernel(FilterType type, double cutoff, double q, int taps, double sampleRate,
                             const double* window, double* kernel) noexcept {
    const int count = linearPhaseTaps(taps);
    const int centre = (count - 1) / 2;
    std::fill(kernel, kernel + count, 0.0);
    const double top = 0.49 * sampleRate;
    const double middle = std::clamp(cutoff, 10.0, top);
    // A band-pass of the same width in octaves as a biquad with this Q.
    const double bandwidth = 2.0 * std::asinh(1.0 / (2.0 * std::clamp(q, 0.1, 20.0))) / std::log(2.0);
    const double low = std::clamp(middle * std::pow(2.0, -bandwidth / 2.0), 5.0, top);
    const double high = std::clamp(middle * std::pow(2.0, bandwidth / 2.0), 5.0, top);
    switch (type) {
    case FilterType::lowpass:
        addLowpass(kernel, count, middle, sampleRate, window, 1.0);
        break;
    case FilterType::highpass:
        kernel[centre] += 1.0;
        addLowpass(kernel, count, middle, sampleRate, window, -1.0);
        break;
    case FilterType::bandpass:
        addLowpass(kernel, count, high, sampleRate, window, 1.0);
        addLowpass(kernel, count, low, sampleRate, window, -1.0);
        break;
    case FilterType::notch:
        kernel[centre] += 1.0;
        addLowpass(kernel, count, high, sampleRate, window, -1.0);
        addLowpass(kernel, count, low, sampleRate, window, 1.0);
        break;
    }
}

void renderLinearPhaseFilter(FilterType type, int taps, const ParameterSignal& cutoff, const ParameterSignal& q,
                             const ParameterSignal& drive, double sampleRate,
                             const float* input, std::size_t inputFrames,
                             float* output, std::size_t frameOffset, std::size_t count, double* scratch) noexcept {
    renderLinearPhaseFilter(type, ParameterSignal(), taps, cutoff, q, drive, sampleRate, input, inputFrames, output,
                            frameOffset, count, scratch);
}

void renderLinearPhaseFilter(FilterType type, const ParameterSignal& typeIndex, int taps, const ParameterSignal& cutoff,
                             const ParameterSignal& q, const ParameterSignal& drive, double sampleRate,
                             const float* input, std::size_t inputFrames,
                             float* output, std::size_t frameOffset, std::size_t count, double* scratch) noexcept {
    if (input == nullptr || output == nullptr || scratch == nullptr || count == 0 || !(sampleRate > 0)) {
        return;
    }
    const bool modulated = cutoff.modulation != nullptr || q.modulation != nullptr || typeIndex.modulation != nullptr;
    const std::size_t size = modulated ? modulatedTransformSize(taps) : staticTransformSize(taps);
    Workspace w = carve(taps, size, scratch);
    const std::size_t m = static_cast<std::size_t>(reach(taps));
    // The twiddles and window are the same every call; computing them here keeps the function stateless.
    fftTwiddles(size, scratch, scratch + size / 2);
    kaiserWindow(taps, scratch + 6 * size);

    if (!modulated) {
        const std::size_t block = size - 2 * m;
        prepareKernel(w, type, cutoff.valueAt(0), q.valueAt(0), sampleRate);
        double* result = scratch + 7 * size;   // one block of output
        const std::size_t firstBlock = frameOffset / block;
        const std::size_t lastBlock = (frameOffset + count - 1) / block;
        for (std::size_t j = firstBlock; j <= lastBlock; ++j) {
            const std::size_t blockStart = j * block;
            convolve(w, input, inputFrames, drive, static_cast<long long>(blockStart), block, result);
            const std::size_t from = std::max(blockStart, frameOffset);
            const std::size_t to = std::min(blockStart + block, frameOffset + count);
            for (std::size_t n = from; n < to; ++n) {
                output[n - frameOffset] = static_cast<float>(result[n - blockStart]);
            }
        }
        return;
    }

    // Moving settings: windows of 2 hop frames, a hop apart, each with its own kernel, cross-faded
    // with sin² / cos² weights that sum to 1. Window k covers [k·hop, k·hop + 2·hop) and takes its
    // settings from the middle of that span.
    const std::size_t hop = linearPhaseHop(taps);
    double* previous = scratch + 7 * size;
    double* current = scratch + 8 * size;
    auto compute = [&](long long k, double* destination) {
        const long long centreFrame = std::max<long long>(k * static_cast<long long>(hop) + static_cast<long long>(hop), 0);
        const auto centre = static_cast<std::size_t>(centreFrame);
        prepareKernel(w, choiceAt(typeIndex, centre, type, 4), cutoff.valueAt(centre), q.valueAt(centre), sampleRate);
        convolve(w, input, inputFrames, drive, k * static_cast<long long>(hop), 2 * hop, destination);
    };
    const std::size_t firstBlock = frameOffset / hop;
    const std::size_t lastBlock = (frameOffset + count - 1) / hop;
    compute(static_cast<long long>(firstBlock) - 1, previous);
    for (std::size_t j = firstBlock; j <= lastBlock; ++j) {
        compute(static_cast<long long>(j), current);
        const std::size_t blockStart = j * hop;
        const std::size_t from = std::max(blockStart, frameOffset);
        const std::size_t to = std::min(blockStart + hop, frameOffset + count);
        for (std::size_t n = from; n < to; ++n) {
            const std::size_t u = n - blockStart;
            const double s = std::sin(pi * static_cast<double>(u) / (2.0 * static_cast<double>(hop)));
            const double rising = s * s;
            output[n - frameOffset] = static_cast<float>((1.0 - rising) * previous[hop + u] + rising * current[u]);
        }
        std::swap(previous, current);
    }
}

} // namespace bake::dsp
