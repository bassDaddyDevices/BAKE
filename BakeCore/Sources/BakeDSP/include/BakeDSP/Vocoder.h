#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"
#include "BakeDSP/Stft.h"

// A spectral vocoder: the modulator's band-by-band loudness over time is imposed on the carrier.
// Both are analysed with the reference STFT (4096-point Hann windows, hop 1024, fixed: this node
// hides the frame size). The modulator's spectrum is reduced to `bands` levels per frame by a
// bins-to-bands matrix; each band level is smoothed by an attack/release follower; and the carrier
// spectrum is scaled, bin by bin, by (modulator band level / carrier band level) read from the
// bands at the bin's frequency (shifted for Formant Shift). Dividing by the carrier's own level
// means the carrier's tone or noise decides the pitch and texture and the modulator decides only the
// spectral shape over time, whatever the carrier's own spectrum looks like. Frames are independent
// once the modulator envelope exists, so a render gives the same bits however it is chunked.
//
// The bands-by-frames envelope is small (frames x bands floats), which is why the modulator is
// analysed in one pass up front. The per-frame bins-to-bands step is a (bands x bins) matrix
// multiply; `vocoderBandMatrix` builds that matrix for the GPU and for tests.

namespace bake::dsp {

enum class VocoderSpacing : int { logarithmic = 0, linear = 1, bark = 2, mel = 3 };

inline constexpr int minimumVocoderBands = 16;
inline constexpr int maximumVocoderBands = 256;

struct VocoderSettings {
    int bands = 32;
    VocoderSpacing spacing = VocoderSpacing::logarithmic;
    double attackMilliseconds = 10.0;
    double releaseMilliseconds = 80.0;
    /// 0…1: how much of the modulator's own high-frequency noise is added back (consonants).
    double sibilance = 0.3;
};

/// The fixed STFT layout the Vocoder uses.
StftLayout vocoderLayout() noexcept;

/// `bands` clamped to 16…256.
int vocoderBandCount(const VocoderSettings& settings) noexcept;

/// Lowest and highest band centres: 80 Hz and 16 kHz (or 0.45 x the sample rate if lower).
double vocoderLowHertz() noexcept;
double vocoderHighHertz(double sampleRate) noexcept;

/// Centre frequency of every band, `vocoderBandCount` doubles.
void vocoderBandCenters(const VocoderSettings& settings, double sampleRate, double* centers) noexcept;

/// The dense bins-to-bands matrix, row-major `bands x bins`: triangular weights on the chosen
/// frequency axis, so each bin's weights across bands add up to 1. Bins below the first centre
/// belong wholly to the first band and bins above the last centre to the last.
void vocoderBandMatrix(const VocoderSettings& settings, double sampleRate, float* matrix) noexcept;

/// Mixes the modulator down to mono (the average of its channels; silence past its end or when
/// unwired) into `mono`, `frames` samples.
void vocoderMixModulator(const AudioInput& modulator, std::size_t frames, float* mono) noexcept;

/// Floats of band envelope for a signal of `signalFrames` samples.
std::size_t vocoderEnvelopeFloats(const VocoderSettings& settings, std::size_t signalFrames) noexcept;

/// Doubles of scratch the two functions below need.
std::size_t vocoderScratchDoubles(const VocoderSettings& settings) noexcept;

/// Floats of work space `vocoderRender` needs for a call of up to `maxCount` samples.
std::size_t vocoderWorkFloats(std::size_t maxCount) noexcept;

/// Floats of work space `vocoderAnalyseModulator` needs.
std::size_t vocoderAnalysisWorkFloats() noexcept;

/// Analyses the whole mono modulator once: `envelope[frame * bands + band]` is the attack/release
/// smoothed level of that band in that frame (`vocoderEnvelopeFloats` floats).
void vocoderAnalyseModulator(const VocoderSettings& settings, double sampleRate, const float* modulator,
                             std::size_t signalFrames, float* envelope, double* scratch, float* work) noexcept;

/// Attack, Release (ms) and Sibilance as signals: each is the settings' fixed value unless its signal is
/// modulated, then read at each STFT frame's centre.
struct VocoderModulation {
    ParameterSignal attack;
    ParameterSignal release;
    ParameterSignal sibilance;
};

/// `vocoderAnalyseModulator` with Attack and Release modulatable.
void vocoderAnalyseModulator(const VocoderSettings& settings, const VocoderModulation& modulation, double sampleRate,
                             const float* modulator, std::size_t signalFrames, float* envelope, double* scratch, float* work) noexcept;

/// The analysis in two parts, so the expensive one can run across cores: `vocoderAnalyseLevels` finds the raw band
/// levels of STFT frames `firstFrame …< firstFrame + frameCount` (independent of each other, so any split gives the same
/// values) into `levels[frame * bands + band]` (`vocoderLevelDoubles` doubles for the whole signal), and
/// `vocoderSmoothLevels` then runs the attack/release followers over all of them in order. Together they give
/// exactly `vocoderAnalyseModulator`'s envelope.
std::size_t vocoderStftFrames(std::size_t signalFrames) noexcept;

std::size_t vocoderLevelDoubles(const VocoderSettings& settings, std::size_t signalFrames) noexcept;

void vocoderAnalyseLevels(const VocoderSettings& settings, double sampleRate, const float* modulator,
                          std::size_t signalFrames, std::size_t firstFrame, std::size_t frameCount,
                          double* levels, double* scratch, float* work) noexcept;

void vocoderSmoothLevels(const VocoderSettings& settings, const VocoderModulation& modulation, double sampleRate,
                         std::size_t signalFrames, const double* levels, float* envelope) noexcept;

/// Renders absolute samples `frameOffset … + count` of the vocoded signal for one carrier channel
/// into `output`. `carrier` and `modulator` point at sample 0 of equal-length signals of
/// `signalFrames` samples (the modulator is read for sibilance only); `envelope` comes from
/// `vocoderAnalyseModulator`. Formant Shift (semitones) and Mix are read at each frame's centre
/// and at each sample.
void vocoderRender(const VocoderSettings& settings, double sampleRate,
                   const ParameterSignal& formantShift, const ParameterSignal& mix,
                   const float* carrier, const float* modulator, std::size_t signalFrames, const float* envelope,
                   float* output, std::size_t frameOffset, std::size_t count,
                   double* scratch, float* work) noexcept;

/// `vocoderRender` with Sibilance modulatable.
void vocoderRender(const VocoderSettings& settings, const VocoderModulation& modulation, double sampleRate,
                   const ParameterSignal& formantShift, const ParameterSignal& mix,
                   const float* carrier, const float* modulator, std::size_t signalFrames, const float* envelope,
                   float* output, std::size_t frameOffset, std::size_t count,
                   double* scratch, float* work) noexcept;

} // namespace bake::dsp
