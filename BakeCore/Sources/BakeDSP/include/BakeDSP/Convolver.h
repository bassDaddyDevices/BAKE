#pragma once

#include <cstddef>

namespace bake::dsp {

/// Partitioned FFT convolution (uniform partitions, overlap-save). The whole input and the whole impulse response are
/// known before the node renders, so every output block can be computed on its own from cached spectra: no state runs
/// from one block to the next, and the result is the same at any chunk size or core count.
///
/// Blocks are `convolverBlock` frames; transforms are twice that. A spectrum is stored as `convolverBins` complex
/// values, interleaved (re, im) as floats.
inline constexpr std::size_t convolverBlock = 4096;
inline constexpr std::size_t convolverBins = convolverBlock + 1;
inline constexpr std::size_t convolverSpectrumFloats = convolverBins * 2;

/// Partitions of an impulse response of `irFrames` frames, and spectra of an input of `inputFrames` frames.
std::size_t convolverPartitionCount(std::size_t irFrames) noexcept;
std::size_t convolverInputBlockCount(std::size_t inputFrames) noexcept;
/// Blocks of output needed for `outputFrames` frames.
std::size_t convolverOutputBlockCount(std::size_t outputFrames) noexcept;

/// Doubles of scratch each worker needs; `convolverPrepareScratch` fills in its twiddle tables once.
std::size_t convolverScratchDoubles() noexcept;
void convolverPrepareScratch(double* scratch) noexcept;

/// Spectrum of partition `partition` of an impulse response (`convolverSpectrumFloats` floats at `out`).
void convolverImpulseSpectrum(const float* impulse, std::size_t impulseFrames, std::size_t partition, double* scratch, float* out) noexcept;

/// Spectrum of input window `index`: frames `[(index − 1) × block, (index + 1) × block)`, zero outside the input.
void convolverInputSpectrum(const float* input, std::size_t inputFrames, std::size_t index, double* scratch, float* out) noexcept;

/// Output block `block` (frames `[block × convolverBlock, …)`, `convolverBlock` floats at `out`): the sum over
/// `pairCount` (input, impulse) spectrum sets, each holding every input window and every partition in order.
void convolverRenderBlock(const float* const* inputSpectra, const float* const* impulseSpectra, std::size_t pairCount,
                          std::size_t inputWindows, std::size_t partitions, std::size_t block, double* scratch, float* out) noexcept;

/// What the impulse response becomes before convolution: the first `trimFrames` frames (0 = all), reversed if asked,
/// resampled by `stretch` (4-point Hermite; above 1 is longer and lower), scaled so its loudest channel has unit energy
/// if `normalize`, then `preDelayFrames` of silence in front. `outFrames` is the length `ConvolverPlan` gives.
void convolverPrepareImpulse(const float* const* source, int channels, std::size_t sourceFrames, std::size_t trimFrames,
                             bool reverse, double stretch, bool normalize, std::size_t preDelayFrames,
                             float* const* out, std::size_t outFrames) noexcept;

} // namespace bake::dsp
