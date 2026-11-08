#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

// Tape Degrade: one pass of a worn tape machine. Wow and flutter move the read position (the whole
// input exists, so there is no delay line and the mean delay is zero: no latency), then saturation,
// a lowpass for the tape's tone, hiss, and dropouts. Hiss and dropouts come from a counter-based hash
// of the seed and the absolute frame or 50 ms block, so any chunking gives the same bits.

struct TapeDegradeControls {
    ParameterSignal wow;         ///< ms, 0–5: read-position depth of the slow wobble
    ParameterSignal flutter;     ///< ms, 0–0.5: depth of the fast wobble
    ParameterSignal saturation;  ///< dB, 0–24: tanh(g·x) / tanh(g)
    ParameterSignal tone;        ///< Hz, 1000–20000: one-pole lowpass
    ParameterSignal mix;         ///< 0–1, against the untouched input
    ParameterSignal wowRate;     ///< Hz, 0.1–4
    ParameterSignal flutterRate; ///< Hz, 4–20
    ParameterSignal hiss;        ///< dB, −120…−30
    ParameterSignal dropouts;    ///< 0–1: chance that a 50 ms block drops out
    std::uint64_t seed = 1;
    double sampleRate = 48000;
    std::size_t channelCount = 1;
};

/// One channel's carried state. Zero-initialise one per channel.
struct TapeDegradeState {
    double wowPhase = 0;     ///< cycles
    double flutterPhase = 0; ///< cycles
    double lowpass = 0;
};

/// Renders absolute frames `frameOffset …` of channel `channel` into `output[0 … count)`. `input`
/// points at frame 0 of the whole channel. Chunks must be consecutive, starting at 0.
void renderTapeDegrade(TapeDegradeState* state, const TapeDegradeControls& controls,
                       const float* input, std::size_t inputFrames, std::size_t channel,
                       float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
