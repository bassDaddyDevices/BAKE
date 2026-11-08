#include "BakeDSP/Fft.h"

#include <cmath>

#if defined(__APPLE__) && !defined(BAKE_REFERENCE_FFT)
#define BAKE_USE_ACCELERATE 1
#include <Accelerate/Accelerate.h>
#endif

namespace bake::dsp {

void fftTwiddles(std::size_t size, double* cosines, double* sines) noexcept {
    constexpr double pi = 3.14159265358979323846;
    for (std::size_t k = 0; k < size / 2; ++k) {
        cosines[k] = std::cos(-2.0 * pi * static_cast<double>(k) / static_cast<double>(size));
        sines[k] = std::sin(-2.0 * pi * static_cast<double>(k) / static_cast<double>(size));
    }
}

#ifdef BAKE_USE_ACCELERATE
namespace {

// A vDSP setup made for 2^n points serves every smaller power of two too, so three tiers cover
// everything the engine asks for (STFT frames are 2^6…2^16; linear-phase filters reach 2^19 and a
// bit more). Function-local statics are created once, thread-safely, when first needed.
constexpr std::size_t smallestAccelerated = 16;

FFTSetupD setupFor(unsigned log2n) noexcept {
    static const FFTSetupD small = vDSP_create_fftsetupD(12, kFFTRadix2);
    static const FFTSetupD medium = vDSP_create_fftsetupD(16, kFFTRadix2);
    static const FFTSetupD large = vDSP_create_fftsetupD(20, kFFTRadix2);
    if (log2n <= 12) return small;
    if (log2n <= 16) return medium;
    if (log2n <= 20) return large;
    return nullptr;
}

} // namespace
#endif

void fft(double* real, double* imaginary, std::size_t size, const double* cosines, const double* sines) noexcept {
#ifdef BAKE_USE_ACCELERATE
    if (size >= smallestAccelerated && (size & (size - 1)) == 0) {
        const unsigned log2n = static_cast<unsigned>(__builtin_ctzll(size));
        if (const FFTSetupD setup = setupFor(log2n)) {
            DSPDoubleSplitComplex data{real, imaginary};
            vDSP_fft_zipD(setup, &data, 1, log2n, kFFTDirection_Forward);
            return;
        }
    }
#endif
    fftReference(real, imaginary, size, cosines, sines);
}

bool fftUsesAccelerate() noexcept {
#ifdef BAKE_USE_ACCELERATE
    return true;
#else
    return false;
#endif
}

} // namespace bake::dsp
