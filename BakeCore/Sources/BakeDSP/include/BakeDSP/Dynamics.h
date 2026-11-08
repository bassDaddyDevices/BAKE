#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class DynamicsMode : int { compressor = 0, expander = 1, gate = 2 };

/// The static curve and the ballistics. Everything is computed over the whole file, so Attack is true look-ahead:
/// the gain starts to move before the signal that causes it and arrives exactly on it.
/// Attack and Release are the time for the gain change to fall to 10% (a 90% settle).
/// In the compressor, Attack is how early the gain starts to fall and Release is how it recovers. In the expander and
/// gate it is the other way round, as on a gate: Attack is how early it opens, Release is how it closes.
struct DynamicsSettings {
    DynamicsMode mode = DynamicsMode::compressor;
    ParameterSignal threshold;      ///< dB
    ParameterSignal ratio;          ///< n:1, 100 and up is infinite
    double kneeDb = 6;
    double attackMs = 5;
    double releaseMs = 120;
    double holdMs = 0;
    double hysteresisDb = 3;        ///< expander and gate: closes this far under the threshold
    double rangeDb = 60;            ///< expander and gate: the deepest reduction
    double sampleRate = 48000;
};

/// Level in dB (floored at -120) of channel `channel` of the detector input, per frame. `rms` uses a centred window
/// of `windowMs`, otherwise it's the absolute sample. A detector with fewer channels than `channel` repeats its last.
void dynamicsLevels(const AudioInput& detector, int channel, bool rms, double windowMs, double sampleRate,
                    std::size_t frames, float* levelsDb) noexcept;

/// The same, with the detector first run through a 2nd-order Butterworth high-pass at `highPassHz` and low-pass at
/// `lowPassHz` (0 leaves that side open), so bass or sibilance can be kept out of what the compressor reacts to.
/// `scratch` holds `frames` floats.
void dynamicsLevelsFiltered(const AudioInput& detector, int channel, double highPassHz, double lowPassHz, bool rms,
                            double windowMs, double sampleRate, std::size_t frames, float* levelsDb, float* scratch) noexcept;

/// Blends each channel's level toward the loudest channel's: `link` 1 uses the loudest for all, 0 leaves them apart.
void dynamicsLink(float* const* levelsDb, int channelCount, std::size_t frames, double link) noexcept;

/// Level to gain: the static curve, then look-ahead and hold/release. `gainDb` is 0 or negative.
void dynamicsGainCurve(const float* levelsDb, std::size_t frames, const DynamicsSettings& settings, float* gainDb) noexcept;

/// Integrated loudness (BS.1770-4, gated) of `input` with `gainDb` applied. `curveCount` is 1 (one curve for every
/// channel) or the channel count; a null `gainDb` measures the input as it is. -1000 when it is silent.
double dynamicsLoudness(const AudioInput& input, const float* const* gainDb, int curveCount, double sampleRate) noexcept;

/// Frames `[frameOffset, frameOffset + count)` of every output channel: dry × (1 − mix) + input × gain × makeup × mix.
/// `makeup` is in dB per frame, plus `extraMakeupDb` (the auto makeup). Stateless.
void dynamicsRender(const AudioInput& input, const float* const* gainDb, int curveCount, const ParameterSignal& makeup,
                    double extraMakeupDb, const ParameterSignal& mix, float* const* outputs, int channelCount,
                    std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
