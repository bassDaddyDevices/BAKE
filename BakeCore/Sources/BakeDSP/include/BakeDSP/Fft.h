#pragma once

#include <cstddef>
#include <utility>

namespace bake::dsp {

/// Smallest power of two that is at least `value` (and at least 2).
inline std::size_t nextPowerOfTwo(std::size_t value) noexcept {
    std::size_t size = 2;
    while (size < value) {
        size <<= 1;
    }
    return size;
}

/// Twiddle factors for an FFT of `size` points (a power of two): `size / 2` cosines and sines of -2πk/size.
void fftTwiddles(std::size_t size, double* cosines, double* sines) noexcept;

/// The portable radix-2 FFT: in place, `size` points, twiddles from `fftTwiddles`. It is the
/// reference every other transform is tested against, and what runs off the Mac.
inline void fftReference(double* real, double* imaginary, std::size_t size, const double* cosines, const double* sines) noexcept {
    for (std::size_t i = 1, j = 0; i < size; ++i) {
        std::size_t bit = size >> 1;
        for (; j & bit; bit >>= 1) {
            j ^= bit;
        }
        j ^= bit;
        if (i < j) {
            std::swap(real[i], real[j]);
            std::swap(imaginary[i], imaginary[j]);
        }
    }
    for (std::size_t length = 2; length <= size; length <<= 1) {
        const std::size_t stride = size / length;
        for (std::size_t start = 0; start < size; start += length) {
            for (std::size_t k = 0; k < length / 2; ++k) {
                const double wr = cosines[k * stride], wi = sines[k * stride];
                const std::size_t a = start + k, b = start + k + length / 2;
                const double tr = real[b] * wr - imaginary[b] * wi;
                const double ti = real[b] * wi + imaginary[b] * wr;
                real[b] = real[a] - tr;
                imaginary[b] = imaginary[a] - ti;
                real[a] += tr;
                imaginary[a] += ti;
            }
        }
    }
}

/// In-place forward FFT of `size` points (a power of two), e^(-2πikn/size), unscaled. On the Mac
/// this is Accelerate's vDSP (the twiddle tables are then unused); elsewhere it is `fftReference`.
/// Either way the result depends only on the input, so any split of a render into chunks gives
/// the same bits.
void fft(double* real, double* imaginary, std::size_t size, const double* cosines, const double* sines) noexcept;

/// Whether `fft` runs on Accelerate in this build.
bool fftUsesAccelerate() noexcept;

/// In-place inverse FFT (including the 1/size scale): a forward FFT with the real and imaginary
/// parts swapped, which conjugates the transform.
inline void inverseFft(double* real, double* imaginary, std::size_t size, const double* cosines, const double* sines) noexcept {
    fft(imaginary, real, size, cosines, sines);
    const double scale = 1.0 / static_cast<double>(size);
    for (std::size_t i = 0; i < size; ++i) {
        real[i] *= scale;
        imaginary[i] *= scale;
    }
}

} // namespace bake::dsp
