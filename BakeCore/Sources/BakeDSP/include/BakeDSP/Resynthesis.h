#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"
#include "BakeDSP/Quantizer.h"
#include "BakeDSP/Stft.h"

// Spectral Resynthesis: a sound is taken apart into sine partials plus a noise residual and put
// back together. The sines are found by an STFT peak picker (4 frames overlap each sample), joined
// across frames into tracks of up to `partials` oscillators, and re-synthesised sample by sample
// with the frequency gliding and the phase continuing from one frame to the next. What is left
// of each frame's spectrum once the partials' bins are removed is the residual; it is played back
// with random phases, so the noise keeps the sound's colour and loses its detail.
//
// The track table is built once, from the whole signal, before rendering (offline, so the look-ahead is
// free). It holds, for every frame and every partial slot, a frequency, an amplitude and the phase
// at the frame's centre. A slot with amplitude 0 is free. Births and deaths ramp over one hop, and the
// table holds the ramp's other end (a free slot's frequency and phase are those the partial has when it
// starts or stops). Synthesis for one hop depends on just the two table rows around it, so any split
// of a render into chunks gives the same bits.

namespace bake::dsp {

enum class PartialParity : int { all = 0, odd = 1, even = 2 };

inline constexpr int minimumPartials = 16;
inline constexpr int maximumPartials = 16384;

struct ResynthesisSettings {
    int fftSize = 4096;        ///< 1024 … 16384; the hop is a quarter of it
    int partials = 128;        ///< 16 … 16384 oscillators
    double hysteresis = 0.3;   ///< 0…1: how far a partial may wander and how quiet it may get before the track ends
    PartialParity parity = PartialParity::all;
};

/// The STFT layout the settings give (fftSize clamped to a power of two between 1024 and 16384, hop = fftSize / 4).
StftLayout resynthesisLayout(const ResynthesisSettings& settings) noexcept;

/// `partials` clamped to 16…16384.
int resynthesisPartialCount(const ResynthesisSettings& settings) noexcept;

/// Floats in the track table for `signalFrames` samples: 3 per slot (frequency Hz, amplitude, phase radians).
std::size_t resynthesisTableFloats(const ResynthesisSettings& settings, std::size_t signalFrames) noexcept;

/// Bytes of scratch both functions below can share, for renders of up to `maxCount` samples at a time.
std::size_t resynthesisScratchBytes(const ResynthesisSettings& settings, std::size_t maxCount) noexcept;

/// Floats of work space `resynthesisAnalyse` needs.
std::size_t resynthesisAnalysisWorkFloats(const ResynthesisSettings& settings) noexcept;

/// Floats of work space `resynthesisRender` needs for calls of up to `maxCount` samples.
std::size_t resynthesisRenderWorkFloats(const ResynthesisSettings& settings, std::size_t maxCount) noexcept;

/// Finds the partials of the whole `signal` and writes the track table (`resynthesisTableFloats` floats).
void resynthesisAnalyse(const ResynthesisSettings& settings, double sampleRate, const float* signal, std::size_t signalFrames,
                        float* table, void* scratch, float* work) noexcept;

/// Renders absolute samples `frameOffset … + count` into `output`. `tilt` is in dB per octave about 1 kHz
/// (read at each frame's centre); `balance` runs 0 (sines only) … 0.5 (the sound as analysed: sines and
/// residual at full level) … 1 (residual noise only), read at each sample. `noiseSeed` separates the noise of
/// different channels.
void resynthesisRender(const ResynthesisSettings& settings, double sampleRate,
                       const ParameterSignal& tilt, const ParameterSignal& balance,
                       const float* signal, std::size_t signalFrames, const float* table,
                       float* output, std::size_t frameOffset, std::size_t count,
                       unsigned noiseSeed, void* scratch, float* work) noexcept;

/// `resynthesisRender` with the sines already summed (by the GPU oscillator bank): `sines[i]` is the sine sum for sample
/// `frameOffset + i`, as `resynthesisSineParams` describes it. Everything else (residual noise, balance, mix) is unchanged.
void resynthesisRenderWithSines(const ResynthesisSettings& settings, double sampleRate,
                                const ParameterSignal& tilt, const ParameterSignal& balance,
                                const float* signal, std::size_t signalFrames, const float* table,
                                float* output, std::size_t frameOffset, std::size_t count,
                                unsigned noiseSeed, void* scratch, float* work, const float* sines) noexcept;

// The GPU oscillator bank. Hop j of a table runs from frame j's centre to frame j + 1's. For one render range, a hop's
// partials are handed to the GPU as `sineEntryFloats` floats each, in slot order, with free slots left out:
//   [0] phase at the hop's start, in turns (0…1)   [1] frequency in turns per sample, high float   [2] its low float
//   [3] cubic phase term alpha, in turns / sample^2   [4] beta, in turns / sample^3
//   [5] level at the hop's start   [6] level change per sample   [7] unused
// so that sample t of the hop is (level + step t) cos(2 pi (phase + f t + alpha t^2 + beta t^3)), the same path the CPU walks.
// The tilt and Harmonics gains are already inside the levels.
inline constexpr std::size_t sineEntryFloats = 8;

struct SineHops {
    long long first = 0;        ///< first hop of the range
    long long count = 0;        ///< hops in the range (0: no sines)
    long long firstCentre = 0;  ///< sample at which hop 0 starts
    long long hop = 0;          ///< samples per hop
    long long lastHop = 0;      ///< the table's last hop (frames - 2)
};

/// The hops that cover samples `frameOffset … + count` of a `signalFrames`-sample output.
SineHops resynthesisSineHops(const ResynthesisSettings& settings, std::size_t signalFrames, std::size_t frameOffset, std::size_t count) noexcept;

/// Writes hop `hop`'s entries (up to `slots * sineEntryFloats` floats) into `entries` and their number into `*active`.
void resynthesisSineParams(const ResynthesisSettings& settings, double sampleRate, const ParameterSignal& tilt,
                           const float* table, std::size_t slots, std::size_t signalFrames, long long hop,
                           float* entries, unsigned* active) noexcept;

// The table transform: every extra (Pitch, Stretch, Quantize, Freeze, Crystallize, Phase Randomize) is
// a rewrite of the partial table, done once after analysis. For each output frame it picks a source
// position (frame / stretch, held while frozen), interpolates each slot there, moves its frequency,
// scales its level, and rebuilds the phases by integrating frequency hop to hop, so the renderer's cubic
// phase path becomes a clean linear glide. A noise map tells the residual which source frame, pitch
// ratio and gain each output frame uses. Modulated controls are read at each output frame's centre.

/// How a second input B combines with the input (Amount blends each in).
enum class ResynthesisMode : int {
    off = 0,
    cross = 1,       ///< the input's partials at the levels of B's spectral envelope
    morph = 2,       ///< partials paired by frequency order glide from the input's toward B's
    splice = 3,      ///< the input's partials below Split, B's above
    swapNoise = 4,   ///< the input's sines over B's residual
};

struct ResynthesisTransform {
    ParameterSignal pitch;             ///< semitones
    double stretch = 1;                ///< output length ÷ input length (fixed: it sets the length)
    ParameterSignal crystallize;       ///< 0…1: toward the nearest exact harmonic of the row's fundamental
    ParameterSignal quantize;          ///< 0…1: toward the nearest note of `scale`
    QuantizerScale scale = QuantizerScale::chromatic;
    int root = 0;
    ParameterSignal glide;             ///< ms: the time constant of the quantize shift
    ControlInput freeze;               ///< while above 0.5, the sound holds the moment it froze
    ParameterSignal decay;             ///< dB per second while frozen
    ParameterSignal phaseRandomize;    ///< 0…1: seeded per-slot phase offsets
    std::uint32_t seed = 0;
    ResynthesisMode mode = ResynthesisMode::off;   ///< needs a B table; off without one
    ParameterSignal amount;            ///< 0…1
    ParameterSignal split;             ///< Hz, for Splice
};

/// True when the transform would change nothing (Pitch 0, Stretch 1, Quantize 0, Crystallize 0,
/// Phase Randomize 0, none modulated, Freeze unwired, Mode off). Then the plain `resynthesisRender`
/// runs, so saved documents keep their exact bits.
bool resynthesisTransformIsNeutral(const ResynthesisTransform& transform) noexcept;

/// Partial slots in a transformed table: the partial count, or twice it for Morph and Splice (the second
/// bank holds B's partials).
int resynthesisOutputSlots(const ResynthesisSettings& settings, const ResynthesisTransform& transform) noexcept;

/// Floats in a transformed table for an output of `outputFrames` samples.
std::size_t resynthesisOutputTableFloats(const ResynthesisSettings& settings, const ResynthesisTransform& transform,
                                         std::size_t outputFrames) noexcept;

/// Floats per noise-map frame: source frame, pitch ratio, gain, B's residual share, B's source frame.
inline constexpr std::size_t resynthesisNoiseMapStride = 5;

/// Floats in the noise map for an output of `outputFrames` samples.
std::size_t resynthesisNoiseMapFloats(const ResynthesisSettings& settings, std::size_t outputFrames) noexcept;

/// Bytes of scratch `resynthesisTransformTable` needs.
std::size_t resynthesisTransformScratchBytes(const ResynthesisSettings& settings) noexcept;

/// Writes the transformed table (`resynthesisOutputTableFloats` floats) and the noise map from the analysed
/// `sourceTable` of a `sourceFrames`-sample input, and B's table if the mode uses one (else null).
void resynthesisTransformTable(const ResynthesisSettings& settings, double sampleRate, const ResynthesisTransform& transform,
                               const float* sourceTable, std::size_t sourceFrames, const float* bTable, std::size_t bFrames,
                               float* table, std::size_t outputFrames, float* noiseMap, void* scratch) noexcept;

/// `resynthesisRender` for a transformed table: sines from `table` (an `outputFrames`-sample output), the
/// residual from `signal` (and `bSignal` for Swap Noise) through `noiseMap`, with the partials' bins taken
/// from `sourceTable` (and `bTable`). Pass null B pointers when no second input is used.
void resynthesisRenderTransformed(const ResynthesisSettings& settings, double sampleRate, const ResynthesisTransform& transform,
                                  const ParameterSignal& tilt, const ParameterSignal& balance,
                                  const float* signal, std::size_t signalFrames, const float* sourceTable,
                                  const float* bSignal, std::size_t bFrames, const float* bTable,
                                  const float* table, const float* noiseMap, std::size_t outputFrames,
                                  float* output, std::size_t frameOffset, std::size_t count,
                                  unsigned noiseSeed, void* scratch, float* work) noexcept;

/// `resynthesisRenderTransformed` with the sines already summed, as `resynthesisRenderWithSines`.
void resynthesisRenderTransformedWithSines(const ResynthesisSettings& settings, double sampleRate, const ResynthesisTransform& transform,
                                           const ParameterSignal& tilt, const ParameterSignal& balance,
                                           const float* signal, std::size_t signalFrames, const float* sourceTable,
                                           const float* bSignal, std::size_t bFrames, const float* bTable,
                                           const float* table, const float* noiseMap, std::size_t outputFrames,
                                           float* output, std::size_t frameOffset, std::size_t count,
                                           unsigned noiseSeed, void* scratch, float* work, const float* sines) noexcept;

} // namespace bake::dsp
