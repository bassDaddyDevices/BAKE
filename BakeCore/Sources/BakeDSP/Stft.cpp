#include "BakeDSP/Stft.h"

#include <algorithm>
#include <cmath>

#include "BakeDSP/Fft.h"

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

std::size_t size(int value) noexcept { return static_cast<std::size_t>(value); }

/// Frame index of the first frame, relative to a frame centred on sample 0: -(overlap / 2 - 1).
long long firstFrameOffset(const StftLayout& layout) noexcept {
    return -static_cast<long long>(stftOverlap(layout) / 2) + 1;
}

} // namespace

bool stftLayoutIsValid(const StftLayout& layout) noexcept {
    const int n = layout.fftSize;
    if (n < 64 || n > 65536 || (n & (n - 1)) != 0 || layout.hop < 1) {
        return false;
    }
    return (n / 2) % layout.hop == 0;
}

std::size_t stftBinCount(const StftLayout& layout) noexcept { return size(layout.fftSize) / 2 + 1; }

std::size_t stftOverlap(const StftLayout& layout) noexcept { return size(layout.fftSize) / size(layout.hop); }

std::size_t stftFrameCount(const StftLayout& layout, std::size_t signalFrames) noexcept {
    if (signalFrames == 0) {
        return 0;
    }
    return (signalFrames - 1) / size(layout.hop) + stftOverlap(layout);
}

long long stftFrameCenter(const StftLayout& layout, std::size_t frame) noexcept {
    return (static_cast<long long>(frame) + firstFrameOffset(layout)) * layout.hop;
}

StftFrameRange stftFramesCovering(const StftLayout& layout, std::size_t signalFrames,
                                  std::size_t sampleStart, std::size_t sampleCount) noexcept {
    if (sampleCount == 0 || signalFrames == 0) {
        return {};
    }
    const long long half = layout.fftSize / 2;
    const long long hop = layout.hop;
    const long long last = static_cast<long long>(sampleStart + sampleCount - 1);
    // A frame centred on c holds samples c - half … c + half - 1, so sample n lies in the frames with c from n - half + 1 to n + half.
    const long long lowestCenter = static_cast<long long>(sampleStart) - half + 1;
    const long long highestCenter = last + half;
    auto ceilDivide = [](long long a, long long b) { return a >= 0 ? (a + b - 1) / b : -((-a) / b); };
    auto floorDivide = [](long long a, long long b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    const long long firstIndex = std::max<long long>(ceilDivide(lowestCenter, hop) - firstFrameOffset(layout), 0);
    const long long lastIndex = std::min<long long>(floorDivide(highestCenter, hop) - firstFrameOffset(layout),
                                                    static_cast<long long>(stftFrameCount(layout, signalFrames)) - 1);
    if (lastIndex < firstIndex) {
        return {};
    }
    return {static_cast<std::size_t>(firstIndex), static_cast<std::size_t>(lastIndex - firstIndex + 1)};
}

std::size_t stftSpectrumFloats(const StftLayout& layout, std::size_t frameCount) noexcept {
    return frameCount * stftBinCount(layout) * 2;
}

std::size_t stftRowFloats(const StftLayout& layout, std::size_t frameCount) noexcept {
    return frameCount * size(layout.fftSize);
}

std::size_t stftScratchDoubles(const StftLayout& layout) noexcept {
    // window, real, imaginary, and the cosine and sine twiddles (half a transform each).
    return 4 * size(layout.fftSize);
}

void stftWindow(const StftLayout& layout, double* window) noexcept {
    const std::size_t n = size(layout.fftSize);
    for (std::size_t i = 0; i < n; ++i) {
        window[i] = 0.5 - 0.5 * std::cos(2.0 * pi * static_cast<double>(i) / static_cast<double>(n));
    }
}

void stftForward(const StftLayout& layout, const float* signal, std::size_t signalFrames,
                 std::size_t firstFrame, std::size_t frameCount, float* spectrum, double* scratch) noexcept {
    if (signal == nullptr || spectrum == nullptr || scratch == nullptr || !stftLayoutIsValid(layout)) {
        return;
    }
    const std::size_t n = size(layout.fftSize);
    const std::size_t bins = stftBinCount(layout);
    double* window = scratch;
    double* real = scratch + n;
    double* imaginary = scratch + 2 * n;
    double* cosines = scratch + 3 * n;
    double* sines = cosines + n / 2;
    stftWindow(layout, window);
    fftTwiddles(n, cosines, sines);
    for (std::size_t j = 0; j < frameCount; ++j) {
        const long long start = stftFrameCenter(layout, firstFrame + j) - static_cast<long long>(n / 2);
        for (std::size_t i = 0; i < n; ++i) {
            const long long index = start + static_cast<long long>(i);
            const double sample = (index >= 0 && index < static_cast<long long>(signalFrames) && std::isfinite(signal[index])) ? signal[index] : 0.0;
            real[i] = sample * window[i];
            imaginary[i] = 0.0;
        }
        fft(real, imaginary, n, cosines, sines);
        for (std::size_t b = 0; b < bins; ++b) {
            spectrum[(j * bins + b) * 2] = static_cast<float>(real[b]);
            spectrum[(j * bins + b) * 2 + 1] = static_cast<float>(imaginary[b]);
        }
    }
}

void stftInverseRows(const StftLayout& layout, const float* spectrum, std::size_t frameCount,
                     float* rows, double* scratch) noexcept {
    if (spectrum == nullptr || rows == nullptr || scratch == nullptr || !stftLayoutIsValid(layout)) {
        return;
    }
    const std::size_t n = size(layout.fftSize);
    const std::size_t bins = stftBinCount(layout);
    double* window = scratch;
    double* real = scratch + n;
    double* imaginary = scratch + 2 * n;
    double* cosines = scratch + 3 * n;
    double* sines = cosines + n / 2;
    stftWindow(layout, window);
    fftTwiddles(n, cosines, sines);
    for (std::size_t j = 0; j < frameCount; ++j) {
        for (std::size_t b = 0; b < bins; ++b) {
            const double re = spectrum[(j * bins + b) * 2];
            const double im = spectrum[(j * bins + b) * 2 + 1];
            // DC and Nyquist of a real signal are real.
            real[b] = re;
            imaginary[b] = (b == 0 || b == n / 2) ? 0.0 : im;
            if (b != 0 && b != n / 2) {
                real[n - b] = re;
                imaginary[n - b] = -im;
            }
        }
        inverseFft(real, imaginary, n, cosines, sines);
        for (std::size_t i = 0; i < n; ++i) {
            rows[j * n + i] = static_cast<float>(real[i] * window[i]);
        }
    }
}

void stftOverlapAdd(const StftLayout& layout, const double* window, const float* rows,
                    std::size_t firstRowFrame, std::size_t rowCount, std::size_t signalFrames,
                    std::size_t sampleStart, std::size_t sampleCount, float* output) noexcept {
    if (window == nullptr || rows == nullptr || output == nullptr || !stftLayoutIsValid(layout)) {
        return;
    }
    const long long n = layout.fftSize;
    for (std::size_t k = 0; k < sampleCount; ++k) {
        const long long sample = static_cast<long long>(sampleStart + k);
        if (sample >= static_cast<long long>(signalFrames)) {
            output[k] = 0.0f;
            continue;
        }
        double sum = 0.0;
        double weight = 0.0;
        for (std::size_t r = 0; r < rowCount; ++r) {
            const long long center = stftFrameCenter(layout, firstRowFrame + r);
            const long long position = sample - center + n / 2;   // index into the row
            if (position < 0 || position >= n) {
                continue;
            }
            sum += rows[r * static_cast<std::size_t>(n) + static_cast<std::size_t>(position)];
            weight += window[position] * window[position];
        }
        output[k] = weight > 0.0 ? static_cast<float>(sum / weight) : 0.0f;
    }
}

void stftMagnitudes(const float* spectrum, std::size_t frameCount, std::size_t bins, float* magnitudes) noexcept {
    if (spectrum == nullptr || magnitudes == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < frameCount * bins; ++i) {
        magnitudes[i] = std::hypot(spectrum[2 * i], spectrum[2 * i + 1]);
    }
}

void stftTriangularBands(const StftLayout& layout, double sampleRate, std::size_t bands,
                         double lowHz, double highHz, float* matrix) noexcept {
    if (matrix == nullptr || bands == 0 || !(sampleRate > 0) || !stftLayoutIsValid(layout)) {
        return;
    }
    const std::size_t bins = stftBinCount(layout);
    const double binHz = sampleRate / static_cast<double>(layout.fftSize);
    const double low = std::log(std::max(lowHz, binHz));
    const double high = std::log(std::max(highHz, lowHz * 1.0001));
    // Band centres at equal steps on a log axis; one band is just its centre.
    const double step = bands > 1 ? (high - low) / static_cast<double>(bands - 1) : 1.0;
    for (std::size_t band = 0; band < bands; ++band) {
        const double centre = low + step * static_cast<double>(band);
        for (std::size_t bin = 0; bin < bins; ++bin) {
            const double hertz = std::max(static_cast<double>(bin) * binHz, 1e-9);
            const double distance = std::fabs(std::log(hertz) - centre) / step;
            matrix[band * bins + bin] = static_cast<float>(std::max(0.0, 1.0 - distance));
        }
    }
}

void stftApplyBands(const float* magnitudes, std::size_t frameCount, std::size_t bins,
                    const float* matrix, std::size_t bands, float* out) noexcept {
    if (magnitudes == nullptr || matrix == nullptr || out == nullptr) {
        return;
    }
    for (std::size_t frame = 0; frame < frameCount; ++frame) {
        for (std::size_t band = 0; band < bands; ++band) {
            double sum = 0.0;
            for (std::size_t bin = 0; bin < bins; ++bin) {
                sum += static_cast<double>(matrix[band * bins + bin]) * magnitudes[frame * bins + bin];
            }
            out[frame * bands + band] = static_cast<float>(sum);
        }
    }
}

void stftApplyGains(float* spectrum, std::size_t frameCount, std::size_t bins, const float* gains) noexcept {
    if (spectrum == nullptr || gains == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < frameCount * bins; ++i) {
        spectrum[2 * i] *= gains[i];
        spectrum[2 * i + 1] *= gains[i];
    }
}

} // namespace bake::dsp
