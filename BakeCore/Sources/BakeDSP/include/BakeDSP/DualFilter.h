#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Filters.h"
#include "BakeDSP/Modulation.h"
#include "BakeDSP/Oversampling.h"

namespace bake::dsp {

// Dual Filter: two filter paths (Alpha and Beta) a Spread apart around Cutoff, swept by an internal
// LFO (Beta against Alpha when Inverted), and blended by an equal-power Morph. Drive (tanh, unity
// small-signal gain) comes before both. Coefficients update on absolute 32-frame blocks, or every
// frame with `perSample`. Up to 32 sections per path (384 dB/oct). `renderDualFilterZeroPhase` runs
// each path forward then backward over the whole file (no phase shift, squared magnitude), and
// `renderDualFilterDrive` is Drive oversampled up to 256x.

/// Most biquad sections one path can have (Slope 384 dB/oct).
inline constexpr int maxDualFilterSections = 32;

/// The catalog's `lfoShape` options, in order.
enum class DualFilterLFOShape : int { sine = 0, triangle = 1, saw = 2, square = 3, sampleAndHold = 4 };

struct DualFilterControls {
    ParameterSignal cutoff;    ///< Hz, 20–20000
    ParameterSignal q;         ///< 0.1–20
    ParameterSignal bandwidth; ///< octaves, 0–4: Alpha sits half above Cutoff, Beta half below
    ParameterSignal morph;     ///< 0 = Alpha, 1 = Beta (equal power)
    ParameterSignal lfoRate;   ///< Hz, 0.01–50
    ParameterSignal lfoDepth;  ///< 0–1: ±2 octaves at 1
    ParameterSignal drive;     ///< dB, 0–24
    ParameterSignal mix;       ///< 0–1
    ParameterSignal alphaTypeIndex; ///< option index of FilterType, when modulated
    ParameterSignal betaTypeIndex;
    ParameterSignal lfoShapeIndex;  ///< option index of DualFilterLFOShape
    ParameterSignal lfoPhaseIndex;  ///< 0 = inverted, 1 = in phase
    FilterType alphaType = FilterType::lowpass;
    FilterType betaType = FilterType::highpass;
    DualFilterLFOShape lfoShape = DualFilterLFOShape::sine;
    bool inverted = true;
    int sections = 2; ///< Slope / 12
    bool perSample = false; ///< coefficients every frame instead of every 32
    std::uint64_t seed = 1;
    double sampleRate = 48000;
};

/// One channel's carried state. Zero-initialise one per channel (the LFO runs identically in each).
struct DualFilterPath {
    double z1[maxDualFilterSections] = {};
    double z2[maxDualFilterSections] = {};
    BiquadCoefficients coefficients;
    bool hasCoefficients = false;
};

struct DualFilterState {
    DualFilterPath alpha;
    DualFilterPath beta;
    double phase = 0;            ///< LFO, cycles
    std::uint64_t cycle = 0;     ///< LFO cycles completed (Sample & Hold index)
};

/// Filters `count` frames of one channel; `input` and `output` point at absolute frame `frameOffset`.
void renderDualFilter(DualFilterState* state, const DualFilterControls& controls,
                      const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same, taking Drive from `driven` (this chunk's frames, drive already applied) when it is not null.
void renderDualFilterDriven(DualFilterState* state, const DualFilterControls& controls,
                            const float* input, float* output, std::size_t frameOffset, std::size_t count,
                            const float* driven) noexcept;

/// Scratch floats `renderDualFilterDrive` needs for pieces of up to `maxCount` frames.
std::size_t dualFilterDriveScratchFloats(int oversampling, std::size_t maxCount) noexcept;

/// Drive (tanh, unity small-signal gain) at `oversampling`x. Stateless: reads the whole channel
/// (`input` points at frame 0), writes `count` frames for absolute frames `frameOffset …` to `output[0 …)`.
void renderDualFilterDrive(const DualFilterControls& controls, int oversampling,
                           const float* input, std::size_t inputFrames,
                           float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept;

/// Doubles `renderDualFilterZeroPhase` needs for a channel of `frames` frames.
std::size_t dualFilterZeroPhaseScratchDoubles(std::size_t frames, bool perSample) noexcept;

/// Zero-phase Dual Filter over a whole channel: forward then backward through each path (coefficients
/// follow the same absolute frames both ways), then Morph and Mix. `driven` is the drive-applied
/// signal, or null to apply Drive here. `output` and `input` are frame 0 … `frames`.
void renderDualFilterZeroPhase(const DualFilterControls& controls, const float* input, const float* driven,
                               std::size_t frames, float* output, double* scratch) noexcept;

} // namespace bake::dsp
