#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"
#include "BakeDSP/Stft.h"

// OTFT Compressor: a compressor on every STFT bin (or on log-spaced groups of bins), each with its own envelope
// follower and a dual-threshold gain curve (downward compression above one threshold, upward below another).
//
// The data flow, all over the whole file and all stateless per frame block except the follower, which runs along
// time for one unit (bin or group) at a time and is independent of every other unit:
//   1. levels    frames of the detector's spectrum → dB per unit        (`otftLevels`, frame blocks across cores)
//   2. gains     per-unit envelope follower + gain computer + time smoothing, in place (`otftGainColumns`: unit blocks across
//                cores on the CPU, or one GPU thread per unit; the GPU kernel is `otftEnvelope` in OtftCompressor.metal and must
//                stay the same arithmetic)
//   3. render    frame blocks: analysis, gains expanded to bins and smoothed across frequency, synthesis (`otftRenderBlock`)
// Surfaces are frame-major: `surface[frame * units + unit]`.

namespace bake::dsp {

/// What a frame asks of every unit. Built once per STFT frame from the (modulatable) parameters at the frame's centre.
/// Mirrors `OtftFrameParams` in OtftCompressor.metal: eight floats.
struct OtftFrameParams {
    float downThreshold = -20;   ///< dB
    float downSlope = 0.75f;     ///< 1 − 1/ratio; 1 is a limiter
    float upThreshold = -60;     ///< dB
    float upSlope = 0.5f;        ///< 1 − 1/ratio
    float maxBoost = 24;         ///< dB, the most the upward side may lift
    float attackMs = 10;
    float releaseMs = 100;
    float padding = 0;
};

/// The static behaviour shared by every unit and frame. Mirrors `OtftUniforms`.
struct OtftEnvelope {
    float hopMilliseconds = 10;
    float kneeDb = 6;
    std::uint32_t anticipating = 0;   ///< 0 causal follower; 1 look-ahead (the gain starts before a loud frame)
    std::uint32_t smoothFrames = 0;   ///< radius of the time smoothing of the gain, in frames
};

/// A level of 0 dB means a full-scale sine; this is the floor.
inline constexpr float otftFloorDb = -120.0f;

/// Groups of bins: `requested` log-spaced groups (0 or at least the bin count means every bin is its own unit).
/// Returns the number of units; `edges` (units + 1 entries) holds each unit's first bin and, last, the bin count.
/// Groups too narrow to hold a bin are merged into their neighbours, so there may be fewer than requested.
std::size_t otftUnitCount(const StftLayout& layout, std::size_t requested) noexcept;
void otftUnitEdges(const StftLayout& layout, std::size_t requested, std::uint32_t* edges) noexcept;

/// Breakpoints of the Threshold Curve: frequency (Hz) and offset (dB), ascending in frequency.
struct OtftCurvePoint {
    float hertz = 0;
    float decibels = 0;
};

/// Per unit: how much Time Tilt scales its attack and release (`timeScale`) and how far the Threshold Curve moves its
/// thresholds (`offsetDb`, relative to the curve's value at 1 kHz). `tilt` is 0…1: at 1, a bin an octave up has half the
/// attack and release. `curve` may be null.
void otftUnitTables(const StftLayout& layout, double sampleRate, const std::uint32_t* edges, std::size_t units,
                    double tilt, const OtftCurvePoint* curve, std::size_t curvePoints, float* timeScale,
                    float* offsetDb) noexcept;

/// For each bin, the unit below it and the weight of the unit above it (0 when it sits at or beyond the end units):
/// the gain of a bin is `(1 − weight) × gain[lower] + weight × gain[lower + 1]` in dB, interpolated in log frequency.
void otftBinMap(const StftLayout& layout, const std::uint32_t* edges, std::size_t units, std::uint32_t* lower,
                float* weight) noexcept;

/// Fills `out[0 ..< frameCount]` from the parameters at the centre of each frame.
void otftFrameParams(const StftLayout& layout, std::size_t signalFrames, std::size_t frameCount,
                     const ParameterSignal& downThreshold, const ParameterSignal& downRatio,
                     const ParameterSignal& upThreshold, const ParameterSignal& upRatio,
                     const ParameterSignal& maxBoost, const ParameterSignal& attack, const ParameterSignal& release,
                     OtftFrameParams* out) noexcept;

/// Doubles `otftLevels` and `otftRenderBlock` need as scratch (on top of `stftScratchDoubles`; see there).
std::size_t otftScratchDoubles(const StftLayout& layout) noexcept;

/// Level in dB of every unit of `frameCount` frames starting at `firstFrame`, written to `levels[(frame − firstFrame)
/// × units + unit]` rows... when `combineMax` is set, each value is the larger of what is already there and the new one
/// (to link channels). `spectrum` is `frameCount × bins × 2` floats of scratch. `signal` is read in place.
void otftLevels(const StftLayout& layout, const float* signal, std::size_t signalFrames, std::size_t firstFrame,
                std::size_t frameCount, const std::uint32_t* edges, std::size_t units, bool combineMax, float* levels,
                float* spectrum, double* scratch) noexcept;

/// The follower, the gain computer and the time smoothing for units `[firstUnit, firstUnit + unitCount)`, in place on
/// `surface` (levels in, gain in dB out). `column` is `frameCount` floats of scratch.
void otftGainColumns(const OtftFrameParams* frames, std::size_t frameCount, std::size_t units, std::size_t firstUnit,
                     std::size_t unitCount, const float* timeScale, const float* offsetDb, const OtftEnvelope& envelope,
                     float* surface, float* column) noexcept;

/// The gain of one unit at one frame from its envelope level. The same arithmetic as the GPU kernel.
float otftGainDb(float levelDb, const OtftFrameParams& frame, float offsetDb, float kneeDb) noexcept;

/// Floats `otftRenderBlock` needs as scratch for `count` output samples.
std::size_t otftRenderFloats(const StftLayout& layout, std::size_t count) noexcept;

/// Output samples `[sampleStart, sampleStart + count)` of the compressed `signal`: each covering frame's spectrum
/// is analysed, every bin multiplied by its gain from `surface` (expanded from units, smoothed across `smoothFreq`
/// 0…1 of 10% of each bin's frequency), and synthesised. Stateless.
void otftRenderBlock(const StftLayout& layout, const double* window, const float* signal, std::size_t signalFrames,
                     const float* surface, std::size_t units, const std::uint32_t* lower, const float* weight,
                     double smoothFreq, std::size_t sampleStart, std::size_t count, float* output, float* floats,
                     double* scratch) noexcept;

/// `out[i] = (dry × (1 − mix) + wet × mix) × 10^((outputGain + makeupDb) / 20)` for frames `[frameOffset, ...)`. `dry` may
/// be null (silence). With `includeOutputGain` false the output gain is left out (Auto Makeup measures without it).
void otftMixDown(const ParameterSignal& mix, const ParameterSignal& outputGain, double makeupDb, bool includeOutputGain,
                 const float* dry, const float* wet, std::size_t frameOffset, std::size_t count, float* out) noexcept;

} // namespace bake::dsp
