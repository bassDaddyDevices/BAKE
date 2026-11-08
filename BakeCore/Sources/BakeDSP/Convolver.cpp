#include "BakeDSP/Convolver.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "BakeDSP/Fft.h"
#include "BakeDSP/TimeMap.h"

namespace bake::dsp {
namespace {

constexpr std::size_t transformSize = convolverBlock * 2;

// Scratch layout: re, im (transformSize each), then cosines and sines (convolverBlock each), then acc re/im bins.
struct Scratch {
    double* real;
    double* imaginary;
    double* cosines;
    double* sines;
    double* accumulatorReal;
    double* accumulatorImaginary;
};

Scratch layout(double* scratch) noexcept {
    Scratch s;
    s.real = scratch;
    s.imaginary = s.real + transformSize;
    s.cosines = s.imaginary + transformSize;
    s.sines = s.cosines + convolverBlock;
    s.accumulatorReal = s.sines + convolverBlock;
    s.accumulatorImaginary = s.accumulatorReal + convolverBins;
    return s;
}

} // namespace

std::size_t convolverPartitionCount(std::size_t irFrames) noexcept {
    return std::max<std::size_t>((irFrames + convolverBlock - 1) / convolverBlock, 1);
}

std::size_t convolverInputBlockCount(std::size_t inputFrames) noexcept {
    return (inputFrames + convolverBlock - 1) / convolverBlock + 1;
}

std::size_t convolverOutputBlockCount(std::size_t outputFrames) noexcept {
    return std::max<std::size_t>((outputFrames + convolverBlock - 1) / convolverBlock, 1);
}

std::size_t convolverScratchDoubles() noexcept {
    return transformSize * 2 + convolverBlock * 2 + convolverBins * 2 + 8;
}

void convolverPrepareScratch(double* scratch) noexcept {
    const Scratch s = layout(scratch);
    fftTwiddles(transformSize, s.cosines, s.sines);
}

void convolverImpulseSpectrum(const float* impulse, std::size_t impulseFrames, std::size_t partition, double* scratch, float* out) noexcept {
    const Scratch s = layout(scratch);
    const std::size_t start = partition * convolverBlock;
    for (std::size_t i = 0; i < transformSize; ++i) {
        const std::size_t frame = start + i;
        s.real[i] = i < convolverBlock && frame < impulseFrames && std::isfinite(impulse[frame]) ? static_cast<double>(impulse[frame]) : 0.0;
        s.imaginary[i] = 0.0;
    }
    fft(s.real, s.imaginary, transformSize, s.cosines, s.sines);
    for (std::size_t k = 0; k < convolverBins; ++k) {
        out[2 * k] = static_cast<float>(s.real[k]);
        out[2 * k + 1] = static_cast<float>(s.imaginary[k]);
    }
}

void convolverInputSpectrum(const float* input, std::size_t inputFrames, std::size_t index, double* scratch, float* out) noexcept {
    const Scratch s = layout(scratch);
    const long long start = (static_cast<long long>(index) - 1) * static_cast<long long>(convolverBlock);
    for (std::size_t i = 0; i < transformSize; ++i) {
        const long long frame = start + static_cast<long long>(i);
        s.real[i] = frame >= 0 && static_cast<std::size_t>(frame) < inputFrames && std::isfinite(input[frame])
            ? static_cast<double>(input[frame]) : 0.0;
        s.imaginary[i] = 0.0;
    }
    fft(s.real, s.imaginary, transformSize, s.cosines, s.sines);
    for (std::size_t k = 0; k < convolverBins; ++k) {
        out[2 * k] = static_cast<float>(s.real[k]);
        out[2 * k + 1] = static_cast<float>(s.imaginary[k]);
    }
}

void convolverRenderBlock(const float* const* inputSpectra, const float* const* impulseSpectra, std::size_t pairCount,
                          std::size_t inputWindows, std::size_t partitions, std::size_t block, double* scratch, float* out) noexcept {
    const Scratch s = layout(scratch);
    std::fill(s.accumulatorReal, s.accumulatorReal + convolverBins, 0.0);
    std::fill(s.accumulatorImaginary, s.accumulatorImaginary + convolverBins, 0.0);
    // Window `block − p` meets partition `p`, for every p where that window exists.
    const std::size_t firstPartition = block + 1 > inputWindows ? block + 1 - inputWindows : 0;
    const std::size_t lastPartition = std::min(partitions - 1, block);
    for (std::size_t pair = 0; pair < pairCount; ++pair) {
        for (std::size_t p = firstPartition; p <= lastPartition && firstPartition <= lastPartition; ++p) {
            const float* x = inputSpectra[pair] + (block - p) * convolverSpectrumFloats;
            const float* h = impulseSpectra[pair] + p * convolverSpectrumFloats;
            for (std::size_t k = 0; k < convolverBins; ++k) {
                const double xr = x[2 * k], xi = x[2 * k + 1], hr = h[2 * k], hi = h[2 * k + 1];
                s.accumulatorReal[k] += xr * hr - xi * hi;
                s.accumulatorImaginary[k] += xr * hi + xi * hr;
            }
        }
    }
    // A real signal's spectrum is conjugate-symmetric: rebuild the upper half, then transform back.
    for (std::size_t k = 0; k < convolverBins; ++k) {
        s.real[k] = s.accumulatorReal[k];
        s.imaginary[k] = s.accumulatorImaginary[k];
    }
    for (std::size_t k = 1; k < convolverBlock; ++k) {
        s.real[transformSize - k] = s.accumulatorReal[k];
        s.imaginary[transformSize - k] = -s.accumulatorImaginary[k];
    }
    inverseFft(s.real, s.imaginary, transformSize, s.cosines, s.sines);
    for (std::size_t i = 0; i < convolverBlock; ++i) {
        const double value = s.real[convolverBlock + i];
        out[i] = std::isfinite(value) ? static_cast<float>(value) : 0.0f;
    }
}

void convolverPrepareImpulse(const float* const* source, int channels, std::size_t sourceFrames, std::size_t trimFrames,
                             bool reverse, double stretch, bool normalize, std::size_t preDelayFrames,
                             float* const* out, std::size_t outFrames) noexcept {
    const std::size_t kept = trimFrames > 0 ? std::min(trimFrames, sourceFrames) : sourceFrames;
    const double ratio = stretch > 0 ? stretch : 1.0;
    double largestEnergy = 0;
    std::vector<float> trimmed(kept);
    for (int c = 0; c < channels; ++c) {
        float* destination = out[c];
        std::fill(destination, destination + outFrames, 0.0f);
        for (std::size_t i = 0; i < kept; ++i) {
            const std::size_t from = reverse ? kept - 1 - i : i;
            const float value = source[c][from];
            trimmed[i] = std::isfinite(value) ? value : 0.0f;
        }
        const std::size_t stretched = std::max<std::size_t>(static_cast<std::size_t>(std::llround(static_cast<double>(kept) * ratio)), 1);
        double energy = 0;
        for (std::size_t i = 0; i < stretched && preDelayFrames + i < outFrames; ++i) {
            const float value = ratio == 1.0 ? (i < kept ? trimmed[i] : 0.0f)
                                             : timeMapRead(trimmed.data(), kept, static_cast<double>(i) / ratio);
            destination[preDelayFrames + i] = value;
            energy += static_cast<double>(value) * static_cast<double>(value);
        }
        largestEnergy = std::max(largestEnergy, energy);
    }
    if (normalize && largestEnergy > 0) {
        const float gain = static_cast<float>(1.0 / std::sqrt(largestEnergy));
        for (int c = 0; c < channels; ++c) {
            for (std::size_t i = 0; i < outFrames; ++i) out[c][i] *= gain;
        }
    }
}

} // namespace bake::dsp
