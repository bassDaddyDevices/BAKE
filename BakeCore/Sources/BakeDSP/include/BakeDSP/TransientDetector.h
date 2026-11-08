#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"

namespace bake::dsp {

/// What the detector watches. `energy` is the band's energy (in dB-like log steps), `spectralFlux` the summed rise of
/// each bin's magnitude, `highFrequency` the energy weighted by bin number, which favours clicks and hats.
enum class TransientMode : int { energy = 0, spectralFlux = 1, highFrequency = 2 };

struct TransientSettings {
    TransientMode mode = TransientMode::energy;
    double sensitivity = 0.5;    ///< 0…1; higher finds fainter onsets
    double minGapMilliseconds = 80;
    double lowCut = 20;          ///< Hz, the band the detection function looks at
    double highCut = 20000;
    bool backTrack = true;       ///< place each bang at the start of its attack instead of at the detection peak
    double sampleRate = 48000;
};

/// STFT size and hop for a sample rate (the hop is a quarter of the size). Detection frames are centred on `hop × n`.
std::size_t transientFrameSize(double sampleRate) noexcept;
std::size_t transientHop(double sampleRate) noexcept;
/// Detection frames needed to cover `frames` input frames.
std::size_t transientHopCount(std::size_t frames, double sampleRate) noexcept;
/// Doubles of scratch each worker needs for `transientDetection`.
std::size_t transientScratchDoubles(double sampleRate) noexcept;

/// Fills `detection[firstHop ..< firstHop + count]` with the onset strength of each frame (the rise from the frame
/// before it, never negative). Frames are independent, so ranges may be computed on separate threads, each with its
/// own `scratch`; the result never depends on how the range was split.
void transientDetection(const AudioInput& input, const TransientSettings& settings, std::size_t firstHop,
                        std::size_t count, double* scratch, double* detection) noexcept;

/// The most onsets `transientPick` can return, so the caller can size its buffers.
std::size_t transientMaxOnsets(std::size_t frames, double minGapMilliseconds, double sampleRate) noexcept;

/// Turns the whole file's detection function into onsets: an adaptive threshold, local maxima, the minimum gap and,
/// with Back-track, the start of each attack found in the audio itself. `onsets` are frame numbers in ascending
/// order, `strengths` run 0…1 (the strongest onset is 1). Returns the count (at most `capacity`).
std::size_t transientPick(const AudioInput& input, const TransientSettings& settings, const double* detection,
                          std::size_t hopCount, std::size_t* onsets, float* strengths, std::size_t capacity) noexcept;

/// Writes frames `[frameOffset, frameOffset + count)` of the two outputs: `bang` is 1 for `pulseFrames` (cut short if
/// the next onset comes sooner, so every onset is a rising edge) and 0 otherwise; `strength` holds each onset's
/// strength until the next. Either output may be null. Stateless, so any chunking gives the same bits.
void transientRender(const std::size_t* onsets, const float* strengths, std::size_t onsetCount, std::size_t pulseFrames,
                     float* bang, float* strength, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
