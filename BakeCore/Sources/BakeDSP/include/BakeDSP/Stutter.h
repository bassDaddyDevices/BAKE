#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"
#include "BakeDSP/TimeMap.h"

namespace bake::dsp {

/// Which repeats play backwards.
enum class StutterReverse : int { off = 0, alternate = 1, all = 2 };

/// Stutter's controls, each a signal so any can be modulated. Times are in ms; `repeats` and
/// `reverse` are rounded. Burst values are read as a burst starts (Size, Repeats, Capture, Chance),
/// repeat values as each repeat starts (Shrink, Gate, Decay, Pitch, Pitch Drift, Pan, Pan Drift,
/// Reverse, Jitter; Smooth at each jump), and Every and Mix every frame.
struct StutterControls {
    ParameterSignal every;
    ParameterSignal chance;
    ParameterSignal size;
    ParameterSignal repeats;
    ParameterSignal capture;
    ParameterSignal shrink;
    ParameterSignal gate;
    ParameterSignal decay;
    ParameterSignal pitch;
    ParameterSignal pitchDrift;
    ParameterSignal pan;
    ParameterSignal panDrift;
    ParameterSignal reverse;
    ParameterSignal jitter;
    ParameterSignal smooth;
    ParameterSignal mix;
    double sampleRate = 48000;
    std::uint32_t seed = 0;
};

/// Carried between chunks.
struct StutterState {
    bool started = false;
    double timerPosition = 0;      ///< bursts elapsed, while Every is modulated
    std::int64_t lastBurst = -1;
    std::uint32_t random = 0;
    float previousTrigger = 0;
    bool inBurst = false;
    int repeat = 0;
    int repeats = 0;
    double repeatStart = 0;
    double repeatLength = 0;
    double captureStart = 0;
    double gateOpen = 0;           ///< frames into the repeat the gate stays open
    float level = 1;
    double velocity = 1;
    double oldVelocity = 1;
    float envelope = 1;            ///< the gate, slewed over 1 ms so chops never click
    TimeMapPath path;
};

/// Stutter over one channel of `channelCount`; in stereo, Pan moves each repeat across the two.
/// Bursts start on each bang on `trigger` while it is wired, else every Every ms from frame 0,
/// each with probability Chance (seeded). `input` is the whole channel; `output` is this chunk.
void renderStutter(StutterState* state, const StutterControls& controls, const ControlInput& trigger, int channel,
                   int channelCount, const float* input, std::size_t inputFrames, float* output, std::size_t frameOffset,
                   std::size_t count) noexcept;

} // namespace bake::dsp
