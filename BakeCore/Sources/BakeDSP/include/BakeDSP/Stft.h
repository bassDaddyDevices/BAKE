#pragma once

#include <cstddef>

// A reference short-time Fourier transform for BAKE's spectral nodes. Audio becomes a matrix:
// one row per frame, one complex column per bin. This is the CPU truth that the Metal kernels are
// tested against (GPU engine rule: every kernel has a CPU reference), and the layout they will use.
//
// Layout. Frame j is centred on sample (j + firstFrame) * hop, where the first frame is placed so
// every real sample sits under exactly fftSize / hop overlapping frames (the frames before sample 0
// and after the last sample read silence). Each frame is windowed by a periodic Hann window, so
// analysis followed by synthesis with the same window, divided by the sum of the squared windows
// over the frames that cover a sample, gives the input back exactly (up to rounding).
//
// Everything here reads and writes planar float arrays; a spectrum is stored frame-major with each
// bin as an interleaved (real, imaginary) pair: spectrum[(frame * bins + bin) * 2 + {0, 1}].

namespace bake::dsp {

struct StftLayout {
    int fftSize = 4096; ///< a power of two, 64 … 65536
    int hop = 1024;     ///< divides fftSize / 2, so 2, 4, 8 … frames overlap each sample
};

/// Whether `layout` is one the functions below accept.
bool stftLayoutIsValid(const StftLayout& layout) noexcept;

/// Bins per frame: fftSize / 2 + 1 (DC … Nyquist).
std::size_t stftBinCount(const StftLayout& layout) noexcept;

/// Frames that overlap each sample.
std::size_t stftOverlap(const StftLayout& layout) noexcept;

/// How many frames cover a signal of `signalFrames` samples.
std::size_t stftFrameCount(const StftLayout& layout, std::size_t signalFrames) noexcept;

/// The sample index frame `frame` is centred on (negative for the frames that start before the signal).
long long stftFrameCenter(const StftLayout& layout, std::size_t frame) noexcept;

struct StftFrameRange {
    std::size_t first = 0;
    std::size_t count = 0;
};

/// The frames needed to synthesise samples `sampleStart … sampleStart + sampleCount`.
StftFrameRange stftFramesCovering(const StftLayout& layout, std::size_t signalFrames,
                                  std::size_t sampleStart, std::size_t sampleCount) noexcept;

/// Floats in a spectrum of `frameCount` frames (2 per bin).
std::size_t stftSpectrumFloats(const StftLayout& layout, std::size_t frameCount) noexcept;

/// Floats in `frameCount` frames of time-domain rows (fftSize per frame).
std::size_t stftRowFloats(const StftLayout& layout, std::size_t frameCount) noexcept;

/// Doubles `stftForward` and `stftInverseRows` need as scratch.
std::size_t stftScratchDoubles(const StftLayout& layout) noexcept;

/// The periodic Hann window, `fftSize` doubles.
void stftWindow(const StftLayout& layout, double* window) noexcept;

/// Analysis of frames `firstFrame … firstFrame + frameCount` of `signal` (read in place; samples
/// outside it are silence). Frames are independent, so any split of a render into frame blocks gives
/// the same numbers.
void stftForward(const StftLayout& layout, const float* signal, std::size_t signalFrames,
                 std::size_t firstFrame, std::size_t frameCount, float* spectrum, double* scratch) noexcept;

/// Inverse of one block of frames: each frame's spectrum back to `fftSize` time samples, multiplied
/// by the synthesis window, ready for `stftOverlapAdd`.
void stftInverseRows(const StftLayout& layout, const float* spectrum, std::size_t frameCount,
                     float* rows, double* scratch) noexcept;

/// Overlap-add as a gather, so every output sample has exactly one writer: output sample `n` sums
/// the row samples that fall on it from each frame that covers it, divided by the summed squared
/// window. `rows` holds `rowCount` frames starting at frame `firstRowFrame`; they must include every
/// frame covering `sampleStart … sampleStart + sampleCount`
/// (see `stftFramesCovering`). `window` comes from `stftWindow`.
void stftOverlapAdd(const StftLayout& layout, const double* window, const float* rows,
                    std::size_t firstRowFrame, std::size_t rowCount, std::size_t signalFrames,
                    std::size_t sampleStart, std::size_t sampleCount, float* output) noexcept;

// MARK: Spectral matrices

/// Magnitudes |X| of a spectrum, `frameCount * bins` floats.
void stftMagnitudes(const float* spectrum, std::size_t frameCount, std::size_t bins, float* magnitudes) noexcept;

/// A row-major `bands x bins` matrix of triangular, log-spaced bands from `lowHz` to `highHz`:
/// each band peaks at 1 at its centre and falls to 0 at its neighbours' centres, so between the
/// first and last centre the weights of every bin add up to 1. This is the reference for the
/// bin-to-band matrix multiply a Vocoder does on the GPU.
void stftTriangularBands(const StftLayout& layout, double sampleRate, std::size_t bands,
                         double lowHz, double highHz, float* matrix) noexcept;

/// `out[frame * bands + band] = sum over bins of matrix[band * bins + bin] * magnitudes[frame * bins + bin]`.
void stftApplyBands(const float* magnitudes, std::size_t frameCount, std::size_t bins,
                    const float* matrix, std::size_t bands, float* out) noexcept;

/// Multiplies each bin of a spectrum by the matching gain (`gains` has `frameCount * bins` floats).
/// This is the shape of a spectral mask, gate, or painted erase.
void stftApplyGains(float* spectrum, std::size_t frameCount, std::size_t bins, const float* gains) noexcept;

} // namespace bake::dsp
