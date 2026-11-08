#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"
#include "BakeDSP/TimeMap.h"

namespace bake::dsp {

/// Ping-pong reverses every other pass.
enum class LooperDirection : int { forward = 0, reverse = 1, pingPong = 2 };

/// Where the passes fall, from `LooperPlan` in BakeGraph. Before the passes the input plays live;
/// after them it carries on from the region's end.
struct LooperLayout {
    const std::int64_t* passLengths = nullptr;
    int passCount = 0;
    double regionStart = 0;
    double regionLength = 0;
    double introFrames = 0;
};

/// The per-pass controls, read as each pass starts. Scrub and Crossfade in ms, Pitch in semitones,
/// Direction an index. With `snap`, each pass's read start moves to the nearest rising zero crossing
/// of `snapSource` (the first channel, so every channel loops at the same points) within 5 ms.
struct LooperControls {
    ParameterSignal scrub;
    ParameterSignal direction;
    ParameterSignal pitch;
    ParameterSignal pitchDrift;
    ParameterSignal decay;
    ParameterSignal crossfade;
    double sampleRate = 48000;
    bool snap = false;
    const float* snapSource = nullptr;
    std::size_t snapFrames = 0;
};

/// Repeat mode's timing: a loop starts on each bang on Trigger while it is wired, else every Every
/// ms from frame 0, and captures the Length (ms) of input that follows. Passes and Shrink are read
/// as each loop starts; Every every frame.
struct LooperRepeat {
    ParameterSignal every;
    ParameterSignal length;
    ParameterSignal passes;
    ParameterSignal shrink;
};

/// Carried between chunks.
struct LooperState {
    bool started = false;
    int segment = -1;          ///< −1 intro, 0…passCount − 1 passes, passCount the tail
    double segmentEnd = 0;     ///< output frame the segment ends
    double velocity = 1;
    double oldVelocity = 1;
    float gain = 1;
    TimeMapPath path;
    // Repeat mode.
    float previousTrigger = 0;
    std::int64_t lastBang = -1;
    double timerPosition = 0;  ///< loops elapsed, while Every is modulated
    bool looping = false;
    int pass = 0;
    int passCount = 0;
    double passStart = 0;
    double passLength = 0;
    double captureStart = 0;
};

/// Looper over one channel. `input` is the whole input channel; `output` is this chunk of the
/// (longer) output.
void renderLooper(LooperState* state, const LooperLayout& layout, const LooperControls& controls, const float* input,
                  std::size_t inputFrames, float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// Looper in Repeat mode over one channel: the output is as long as the input, which plays live
/// before the first bang and after a loop's last pass.
void renderLooperRepeat(LooperState* state, const LooperRepeat& repeat, const LooperControls& controls,
                        const ControlInput& trigger, const float* input, std::size_t inputFrames, float* output,
                        std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
