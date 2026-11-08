#pragma once

#include <cstddef>
#include <vector>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

struct LimiterSettings {
    double ceilingDb = -1;       ///< the highest true peak allowed, dBTP
    double lookaheadMs = 5;      ///< how early the gain starts to fall; it falls to 10% of its depth over this time
    double releaseMs = 100;      ///< how slowly it recovers, to 10% of the depth over this time
    double holdMs = 0;           ///< how long the reduction stays at its depth after a peak before Release begins
    double sampleRate = 48000;
};

/// The most reduction (dB) the limiter will ever ask for.
inline constexpr double limiterMaxReductionDb = 96.0;

/// Taps of the interpolator the true-peak measurement uses, for `factor`× oversampling.
std::size_t limiterTapCount(int factor) noexcept;

/// Fills `peaks[0 ..< count]` for frames `firstFrame …`: the highest absolute value, over every channel, of the signal
/// between that frame and the next, found by band-limited interpolation at `factor`× (1 measures the samples only).
/// `taps` holds `limiterTapCount(factor)` floats and must have been filled by `limiterDesign`. Stateless, so any split
/// into pieces gives the same bits.
void limiterDesign(int factor, float* taps) noexcept;
void limiterPeaks(const AudioInput& input, int factor, const float* taps, std::size_t firstFrame, std::size_t count,
                  float* peaks) noexcept;
/// The same for one channel only (`channel` below the input's channel count).
void limiterChannelPeaks(const AudioInput& input, std::size_t channel, int factor, const float* taps,
                         std::size_t firstFrame, std::size_t count, float* peaks) noexcept;

/// What each frame needs on its own: the dB over the Ceiling of `peaks` (linear) after `gain`, 0 or more.
void limiterNeeded(const float* peaks, std::size_t frames, const ParameterSignal& gain, const LimiterSettings& settings,
                   float* neededDb) noexcept;

/// Blends each channel's need toward the largest of them: `link` 1 uses the largest for all, 0 leaves them apart. A channel
/// never needs less than it did, so the ceiling still holds for every channel.
void limiterLink(float* const* neededDb, int channelCount, std::size_t frames, double link) noexcept;

/// From what each frame needs to the reduction curve: Hold, Look-ahead, Release and the corner smoothing. In place.
void limiterCurve(float* neededDb, std::size_t frames, const LimiterSettings& settings, float* reductionDb) noexcept;

/// Solves the whole file for the least reduction curve (dB, ≥ 0) that keeps every peak, after `gain` (dB per frame),
/// at or under the ceiling, and moves no faster than Look-ahead and Release allow: the pointwise minimum of all curves
/// that do. A short smoothing then rounds the corner at each peak without ever dropping under what is needed.
/// `peaks` are linear and `reductionDb` receives the curve.
void limiterSolve(const float* peaks, std::size_t frames, const ParameterSignal& gain, const LimiterSettings& settings,
                  float* reductionDb) noexcept;

/// Frames `[frameOffset, frameOffset + count)` of every output channel: input × gain × reduction. Stateless.
void limiterRender(const AudioInput& input, const float* reductionDb, const ParameterSignal& gain, float* const* outputs,
                   int channelCount, std::size_t frameOffset, std::size_t count) noexcept;
/// One channel with its own curve (used when Link is below 1).
void limiterRenderChannel(const AudioInput& input, std::size_t channel, const float* reductionDb, const ParameterSignal& gain,
                          float* out, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
