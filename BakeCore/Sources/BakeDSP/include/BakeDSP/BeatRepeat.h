#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"
#include "BakeDSP/TimeMap.h"

namespace bake::dsp {

/// Insert: repeats replace the input during events. Mix: repeats join the input. Gate: only repeats.
enum class BeatRepeatMode : int { insert = 0, mix = 1, gate = 2 };

/// Beat Repeat's controls, each a signal so any of them can be modulated. Lengths are musical:
/// `grid` and `interval` are indexes into the note lists (in quarter notes), `gate` and `offset`
/// count sixteenths, `capture` grids, `smooth` milliseconds, `tempo` quarter notes per minute.
/// Event values are read when an event starts, repeat values when a repeat starts.
struct BeatRepeatControls {
    ParameterSignal tempo;
    ParameterSignal interval;     ///< index into `intervalQuarters`; read every frame
    ParameterSignal offset;       ///< sixteenths of the interval; read every frame
    ParameterSignal chance;       ///< per event
    ParameterSignal gate;         ///< per event
    ParameterSignal grid;         ///< index into `gridQuarters`; per event
    ParameterSignal capture;      ///< grids from the event start to the slice (positive = the future); per event
    ParameterSignal variation;    ///< 0–1: up to 3 random grid halvings; per event
    ParameterSignal accelerate;   ///< each repeat's length × this; per repeat
    ParameterSignal pitch;        ///< semitones, repitch; per repeat
    ParameterSignal pitchDrift;   ///< semitones added per repeat; per repeat
    ParameterSignal decay;        ///< each repeat's gain × (1 − decay); per repeat
    ParameterSignal smooth;       ///< jump crossfade in ms, capped to half the repeat; per jump
    const double* gridQuarters = nullptr;
    int gridCount = 0;
    const double* intervalQuarters = nullptr;
    int intervalCount = 0;
    double sampleRate = 48000;
    std::uint32_t seed = 0;
};

/// Carried between chunks.
struct BeatRepeatState {
    bool started = false;
    double intervalPosition = 0;   ///< intervals elapsed, while Tempo or Interval is modulated
    std::int64_t lastInterval = -1;
    std::uint32_t random = 0;
    float previousTrigger = 0;
    bool inEvent = false;
    double eventEnd = 0;
    double grid = 0;
    double capture = 0;
    double sliceStart = 0;
    int repeat = 0;
    double repeatStart = 0;
    double repeatLength = 0;
    float repeatGain = 1;
    double speed = 1;
    TimeMapPath path;
};

/// Beat Repeat over one channel. Events start each interval at the offset with probability Chance
/// (seeded), or on each bang on `trigger` while it is wired. `input` is the whole channel;
/// `output` is this chunk.
void renderBeatRepeat(BeatRepeatState* state, BeatRepeatMode mode, const BeatRepeatControls& controls,
                      const ControlInput& trigger, const float* input, std::size_t inputFrames, float* output,
                      std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
