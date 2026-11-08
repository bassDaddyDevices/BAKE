#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Stft.h"

namespace bake::dsp {

enum class FractalMaskPattern : std::uint32_t {
    cantor = 0,
    mandelbrot = 1,
    julia = 2,
    koch = 3,
};

struct FractalMaskSettings {
    std::uint32_t iterations = 4;
    float warp = 1.0f;
    float center = 0.5f;
    float q = 1.0f;
    FractalMaskPattern pattern = FractalMaskPattern::cantor;
};

/// CPU reference for the Metal recursive mask. `positions` are log-frequency bin positions
/// computed by FractalFilterKernel.position(); output contains `binCount` raw, unnormalised gains.
void fractalMaskRaw(const FractalMaskSettings& settings, const float* positions,
                    std::size_t binCount, float* output) noexcept;

/// Normalises one frame's raw mask with equal-octave 1/k weighting and clamps it to the spec's bounds.
void fractalMaskNormalise(float* rawMask, std::size_t binCount) noexcept;

/// Applies one frame's normalised mask to its interleaved complex spectrum, then rescales the frame
/// to its original energy (at most +24 dB). Phase: 0 preserved, 1 deterministic seeded random,
/// 2 mirrored/conjugated.
void fractalMaskApply(float* spectrum, const float* mask, std::size_t binCount,
                      int phaseMode, std::uint32_t seed, std::uint32_t frameIndex) noexcept;

/// Maximum number of STFT rows needed for any chunk of at most `maxChunkFrames`.
std::size_t fractalFilterMaxRows(const StftLayout& layout, std::size_t maxChunkFrames) noexcept;

/// Filter one channel's chunk using the raw mask rows returned by Metal. All scratch is caller-owned
/// and sized for `frameCount` rows. `phases` contains one mode per row; seed is fixed for the node.
void fractalFilterProcessChannel(const StftLayout& layout, const double* window,
                                 const float* input, std::size_t signalFrames,
                                 std::size_t sampleStart, std::size_t sampleCount,
                                 std::size_t firstFrame, std::size_t frameCount,
                                 float* rawMasks, const std::uint32_t* phases, std::uint32_t seed,
                                 float* spectrum, float* rows, double* stftScratch,
                                 float* output) noexcept;

} // namespace bake::dsp
