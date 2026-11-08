#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

// Sub-Harmonic Synth, the classic analogue octaver. The mono sum is lowpassed (Track Freq), and
// each positive-going zero crossing toggles a flip-flop (−1 octave), whose positive edges toggle a
// second (−2 octaves). The squares follow the input's envelope and are smoothed by two lowpasses
// (Tone) into sine-like subs. The same sub is added to every channel: out = Dry · x + sub.

struct SubHarmonicControls {
    ParameterSignal sub1;    ///< 0–1, level of the octave below
    ParameterSignal sub2;    ///< 0–1, level of two octaves below
    ParameterSignal tone;    ///< Hz, 40–2000: lowpass on the subs
    ParameterSignal dry;     ///< 0–1, level of the input
    ParameterSignal track;   ///< Hz, 40–400: lowpass before the zero-crossing detector
    ParameterSignal release; ///< ms, 10–500: envelope release
    double sampleRate = 48000;
};

/// RBJ biquad state and coefficients (transposed direct form II).
struct SubHarmonicBiquad {
    double b0 = 0, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;
};

/// The whole node's carried state (detection runs once, on the mono sum). Zero-initialise.
struct SubHarmonicState {
    SubHarmonicBiquad trackFilter;
    SubHarmonicBiquad toneFilters[2];
    double envelope = 0;
    float sub1Sign = -1;
    float sub2Sign = -1;
    bool armed = false; ///< the tracked signal has been below −1e-4 since the last crossing
};

/// Renders the mono sub for absolute frames `frameOffset …` into `sub[0 … count)`. Chunks must be
/// consecutive, starting at 0.
void renderSubHarmonic(SubHarmonicState* state, const SubHarmonicControls& controls, const AudioInput& input,
                       float* sub, std::size_t frameOffset, std::size_t count) noexcept;

/// Doubles `renderSubHarmonicWholeFile` needs for a channel of `frames` frames.
std::size_t subHarmonicWholeFileScratchDoubles(std::size_t frames) noexcept;

/// The same sub, built from the whole file at once: the tracking and tone filters run forward then backward (no phase
/// lag, so the sub lines up with the dry signal) and the envelope is read `attack` ahead (the sub starts on the onset, not
/// after it). Writes `frames` samples to `sub` (frame 0 …).
void renderSubHarmonicWholeFile(const SubHarmonicControls& controls, const AudioInput& input, std::size_t frames,
                                float* sub, double* scratch) noexcept;

/// `output[i] = dry · input[frameOffset + i] + sub[i]` for one channel. `input` points at frame 0 of
/// the whole channel (frames past `inputFrames` read 0).
void addSubHarmonic(const SubHarmonicControls& controls, const float* input, std::size_t inputFrames,
                    const float* sub, float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
