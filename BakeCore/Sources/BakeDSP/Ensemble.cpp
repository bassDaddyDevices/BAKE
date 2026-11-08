#include "BakeDSP/Ensemble.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

/// Gives every bin of `spectrum` the magnitude in `magnitudes`, keeping its phase (a silent bin gets phase 0).
void replaceMagnitudes(float* spectrum, const float* magnitudes, std::size_t count) noexcept {
    for (std::size_t i = 0; i < count; ++i) {
        const double re = spectrum[2 * i], im = spectrum[2 * i + 1];
        const double length = std::sqrt(re * re + im * im);
        const double target = magnitudes[i];
        if (length > 1e-30) {
            spectrum[2 * i] = static_cast<float>(re / length * target);
            spectrum[2 * i + 1] = static_cast<float>(im / length * target);
        } else {
            spectrum[2 * i] = static_cast<float>(target);
            spectrum[2 * i + 1] = 0.0f;
        }
    }
}

void synthesise(const StftLayout& layout, const float* spectrum, std::size_t frameCount, std::size_t signalFrames,
                float* rows, float* signal, double* window, double* scratch) noexcept {
    stftInverseRows(layout, spectrum, frameCount, rows, scratch);
    stftOverlapAdd(layout, window, rows, 0, frameCount, signalFrames, 0, signalFrames, signal);
}

} // namespace

double ensembleBin(double* values, std::size_t count, AverageMode mode, double trim) noexcept {
    if (count == 0) return 0.0;
    switch (mode) {
    case AverageMode::median: {
        const std::size_t middle = count / 2;
        std::nth_element(values, values + middle, values + count);
        if (count % 2 == 1) return values[middle];
        const double upper = values[middle];
        return 0.5 * (upper + *std::max_element(values, values + middle));
    }
    case AverageMode::geometric: {
        double sum = 0.0;
        for (std::size_t i = 0; i < count; ++i) {
            if (!(values[i] > 0.0)) return 0.0;
            sum += std::log(values[i]);
        }
        return std::exp(sum / static_cast<double>(count));
    }
    case AverageMode::mean:
    default: {
        const auto cut = static_cast<std::size_t>(std::floor(std::clamp(trim, 0.0, 0.45) * static_cast<double>(count)));
        if (cut > 0) std::sort(values, values + count);
        double sum = 0.0;
        for (std::size_t i = cut; i < count - cut; ++i) sum += values[i];
        return sum / static_cast<double>(count - 2 * cut);
    }
    }
}

void ensembleAverage(const float* magnitudes, std::size_t clips, std::size_t values, AverageMode mode,
                     double trim, double* scratch, float* out) noexcept {
    for (std::size_t i = 0; i < values; ++i) {
        for (std::size_t clip = 0; clip < clips; ++clip) scratch[clip] = magnitudes[clip * values + i];
        out[i] = static_cast<float>(ensembleBin(scratch, clips, mode, trim));
    }
}

std::size_t ensembleTypical(const float* magnitudes, std::size_t clips, std::size_t values, const float* average) noexcept {
    std::size_t best = 0;
    double bestError = INFINITY;
    for (std::size_t clip = 0; clip < clips; ++clip) {
        double error = 0.0;
        for (std::size_t i = 0; i < values; ++i) {
            const double d = static_cast<double>(magnitudes[clip * values + i]) - average[i];
            error += d * d;
        }
        if (error < bestError) {
            bestError = error;
            best = clip;
        }
    }
    return best;
}

std::size_t ensembleScratchDoubles(const StftLayout& layout) noexcept {
    return stftScratchDoubles(layout) + static_cast<std::size_t>(layout.fftSize);
}

void ensembleGriffinLim(const StftLayout& layout, const float* magnitudes, float* spectrum, std::size_t frameCount,
                        std::size_t signalFrames, std::size_t iterations, float* rows, float* signal,
                        double* scratch) noexcept {
    if (!stftLayoutIsValid(layout) || signalFrames == 0) return;
    double* window = scratch;
    double* work = scratch + layout.fftSize;
    stftWindow(layout, window);
    const std::size_t count = frameCount * stftBinCount(layout);
    replaceMagnitudes(spectrum, magnitudes, count);
    for (std::size_t round = 0; round < iterations; ++round) {
        synthesise(layout, spectrum, frameCount, signalFrames, rows, signal, window, work);
        stftForward(layout, signal, signalFrames, 0, frameCount, spectrum, work);
        replaceMagnitudes(spectrum, magnitudes, count);
    }
    synthesise(layout, spectrum, frameCount, signalFrames, rows, signal, window, work);
}

} // namespace bake::dsp
