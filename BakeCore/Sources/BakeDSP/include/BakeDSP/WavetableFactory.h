#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class WavetableMorph : int { linear = 0, spectral, fragments };
enum class WavetablePhase : int { keep = 0, align, minimumCrest, random };
enum class WavetableNormalize : int { off = 0, perFrame, table };
enum class WavetableToggle : int { off = 0, on };

struct WavetableSettings {
    std::size_t frameSize = 2048;
    std::size_t slots = 64;
    std::size_t fragments = 8;
    std::uint64_t seed = 1;
    WavetableMorph morph = WavetableMorph::linear;
    WavetablePhase phase = WavetablePhase::keep;
    WavetableNormalize normalize = WavetableNormalize::perFrame;
    WavetableToggle snap = WavetableToggle::on;
    WavetableToggle dcRemoval = WavetableToggle::on;
    /// Input cycles kept from the sources. The default is the old limit; "whole" patches raise it to fit every input.
    std::size_t maxSourceFrames = 1024;
};

/// Input-cycle frames retained by patches made before `Source` existed (and the default `maxSourceFrames`).
inline constexpr std::size_t wavetableMaxSourceFrames = 1024;

/// Maximum scratch doubles: A/B real and imaginary spectra, plus full-frame FFT twiddle arrays.
inline constexpr std::size_t wavetableFFTWorkspaceDoubles(std::size_t frameSize) noexcept { return 6 * frameSize; }

/// Builds a complete wavetable into `table`. `sources` are mono-summed audio inputs in pin order.
/// `table` must contain `settings.frameSize * settings.slots` floats and scratch must contain at
/// least wavetableFFTWorkspaceDoubles(settings.frameSize) doubles. No allocation occurs here.
void buildWavetable(const WavetableSettings& settings, const AudioInput* sources, std::size_t sourceCount,
                    float* sourceFrames, std::size_t sourceCapacityFrames,
                    float* table, double* scratch) noexcept;

} // namespace bake::dsp
