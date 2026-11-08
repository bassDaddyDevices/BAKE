#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// What Normalize measures the whole file by. `peak` is the sample peak, `rms` the RMS over every channel, `loudness`
/// the integrated loudness of ITU-R BS.1770-4 (K-weighted, gated), in LUFS.
enum class UtilityNormalize : int { off = 0, peak = 1, rms = 2, loudness = 3 };

/// The curve of a fade, 0…1 to 0…1: `linear`, `equalPower` (a quarter sine, so two crossed fades keep their power) or
/// `smooth` (a raised cosine).
enum class UtilityFadeCurve : int { linear = 0, equalPower = 1, smooth = 2 };

/// Fixed for a render, except the two signals.
struct UtilityControls {
    ParameterSignal gain;          ///< dB
    ParameterSignal balance;       ///< −1 (left only) … +1 (right only); touches channels 0 and 1
    float polarity = 1;            ///< 1, or −1 to invert
    double fadeInFrames = 0;
    double fadeOutFrames = 0;
    UtilityFadeCurve fadeCurve = UtilityFadeCurve::linear;
    std::size_t totalFrames = 0;   ///< where the audio ends in the output (its length, plus Pad Start); the fade-out counts back from it
    std::size_t contentStart = 0;  ///< where the audio starts in the output (Pad Start); the fade-in counts from it
    double normalizeGain = 1;      ///< from `utilityNormalizeGain`, 1 when Normalize is off
};

/// The mean of a channel, to subtract for DC Remove.
double utilityDcOffset(const float* input, std::size_t frames) noexcept;

/// The linear gain that brings the whole file to `targetDb` by `mode` (peak dBFS, RMS dBFS, or LUFS), measured after
/// subtracting each channel's `dcOffsets` entry (may be null). 1 for silence or for `off`.
double utilityNormalizeGain(const float* const* channels, int channelCount, std::size_t frames, const double* dcOffsets,
                            UtilityNormalize mode, double targetDb, double sampleRate) noexcept;

/// Integrated loudness in LUFS (ITU-R BS.1770-4: K-weighting, 400 ms blocks at 75% overlap, −70 LUFS absolute gate,
/// −10 LU relative gate). −1000 when nothing passes the gates.
double utilityIntegratedLoudness(const float* const* channels, int channelCount, std::size_t frames,
                                 const double* dcOffsets, double sampleRate) noexcept;

/// The mean of every channel, frame by frame, into `output` (`frames` long). One channel comes through bit for bit.
void utilityMonoSum(const float* const* channels, int channelCount, std::size_t frames, float* output) noexcept;

/// One channel: `output = (input − dcOffset) × normalizeGain × gain × polarity × balance × fades`. `frameOffset` is the
/// absolute frame of `input[0]`/`output[0]`. With every control at rest the output is the input, bit for bit.
void renderUtility(const UtilityControls& controls, int channel, int channelCount, const float* input, float* output,
                   double dcOffset, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
