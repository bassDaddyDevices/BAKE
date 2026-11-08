#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"
#include "BakeDSP/TimeMap.h"

namespace bake::dsp {

/// One step's effect. `BakeGraph`'s `StepFXPattern.Effect` has the same order.
enum class StepEffect : int { pass = 0, stutter = 1, reverse = 2, tapeStop = 3, halfTime = 4, gate = 5 };

/// Step FX's controls. `pattern` holds `steps` effect indices. Times in ms; `step` indexes
/// `stepQuarters` (quarter notes); `rotate` is rounded. Step values are read as each step starts.
struct StepFXControls {
    const int* pattern = nullptr;
    int steps = 0;
    ParameterSignal tempo;
    ParameterSignal step;
    ParameterSignal rotate;
    ParameterSignal chance;
    ParameterSignal variation;
    ParameterSignal stutterSize;
    ParameterSignal speed;
    ParameterSignal curve;
    ParameterSignal gate;
    ParameterSignal smooth;
    ParameterSignal mix;
    const double* stepQuarters = nullptr;
    int stepCount = 0;
    double sampleRate = 48000;
    std::uint32_t seed = 0;
};

/// Carried between chunks.
struct StepFXState {
    bool started = false;
    std::uint32_t random = 0;
    float previousClock = 0;
    double timerPosition = 0;     ///< steps elapsed, while Tempo or Step is modulated
    std::int64_t lastTick = -1;
    bool inStep = false;
    std::int64_t stepNumber = -1;
    int effect = 0;
    double stepStart = 0;
    double stepLength = 0;
    double sliceStart = 0;
    double sliceLength = 0;
    double sliceRepeatStart = 0;
    double gateOpen = 0;
    double curve = 1;
    double velocity = 1;
    double oldVelocity = 1;
    float envelope = 1;
    TimeMapPath path;
};

/// Step FX over one channel. While `clock` is wired each bang starts the next step, and the step
/// lasts until the next bang, found by looking ahead in the clock signal (the last step lasts as
/// long as the one before it). Unwired, steps run at Tempo and Step from frame 0. `input` is the
/// whole channel; `output` is this chunk.
void renderStepFX(StepFXState* state, const StepFXControls& controls, const ControlInput& clock, const float* input,
                  std::size_t inputFrames, float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
