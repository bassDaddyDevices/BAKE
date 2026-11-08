#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"
#include "BakeDSP/TimeMap.h"

namespace bake::dsp {

/// Repitch plays the window slower like tape (lower pitch); Granular keeps the pitch with grains.
enum class HalfTimeMode : int { repitch = 0, granular = 1 };

/// Carried between chunks.
struct HalfTimeState {
    bool started = false;
    double windowStart = 0;
    float previousSync = 0;
    double nextLaunch = 0;    ///< the next grain's frame, while Grain is modulated
    TimeMapPath path;
    TimeMapGrains grains;
};

/// Half Time over one channel. Every window starts at the output's own frame in the source and
/// plays forward at `speed` (0.001–1×). A window starts every `windowFrames`, or on each bang on
/// `sync` (rising above 0.5) while it is wired. Repitch fades each jump over `smoothFrames`;
/// Granular reads `grainFrames` grains. `input` is the whole channel; `output` is this chunk.
void renderHalfTime(HalfTimeState* state, HalfTimeMode mode, const ParameterSignal& speed, const ParameterSignal& mix,
                    double windowFrames, double smoothFrames, int grainFrames, const ControlInput& sync,
                    const float* input, std::size_t inputFrames, float* output, std::size_t frameOffset,
                    std::size_t count) noexcept;

/// Window, Smooth and Grain (ms) modulatable: each is the fixed frame count above unless its signal is
/// modulated. Window is checked every frame, Smooth read at each jump, Grain at each grain's launch
/// (each grain keeps its length, and the next one launches half of it later).
struct HalfTimeModulation {
    ParameterSignal window;
    ParameterSignal smooth;
    ParameterSignal grain;
    double sampleRate = 48000;
};

void renderHalfTime(HalfTimeState* state, HalfTimeMode mode, const ParameterSignal& speed, const ParameterSignal& mix,
                    double windowFrames, double smoothFrames, int grainFrames, const HalfTimeModulation& modulation,
                    const ControlInput& sync, const float* input, std::size_t inputFrames, float* output,
                    std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
