#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

// Granular Cloud: Hann-windowed grains read around the current position. Grain slots sit on a fixed
// 200-per-second grid of absolute frames, and slot k plays when hash(seed, k) falls under
// Density / 200, so the timing is asynchronous at any density up to 200 a second. Past that a slot holds
// several grains (extras start at their own hashed spot inside the slot); at or below 200 the output is
// exactly what it always was. Every grain's offset, pitch, direction and pan come from the hash, and its
// size, spray and pitch are read at its start frame.
// Nothing is carried between calls: any chunking gives the same bits.

inline constexpr double granularSlotsPerSecond = 200;
inline constexpr double granularMaxSizeMs = 2000;
/// Hard bound on grains in one slot (a safety net: the catalog stops at 1,000 a second, 5 grains a slot).
inline constexpr std::uint64_t granularMaxGrainsPerSlot = 1024;

struct GranularCloudControls {
    ParameterSignal size;         ///< ms, 5–2000
    ParameterSignal density;      ///< grains per second, 1–1000
    ParameterSignal spray;        ///< ms, 0–10000: how far a grain's source may stray, either way
    ParameterSignal pitchSpread;  ///< semitones, 0–24, either way
    ParameterSignal mix;          ///< 0–1, against the untouched input
    ParameterSignal pitch;        ///< semitones, −24…+24
    ParameterSignal reverse;      ///< 0–1: chance a grain plays backwards
    ParameterSignal stereoSpread; ///< 0–1: how far grains pan from centre
    std::uint64_t seed = 1;
    double sampleRate = 48000;
};

/// Renders absolute frames `frameOffset …` of output channel `channel` (of `channelCount`) into
/// `output[0 … count)`. `input` points at frame 0 of the whole source channel for this output.
void renderGranularCloud(const GranularCloudControls& controls, const float* input, std::size_t inputFrames,
                         std::size_t channel, std::size_t channelCount,
                         float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
