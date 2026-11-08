#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// `hold`: take the signal's value on each bang and keep it. `trackAndHold`: follow the signal while the trigger is
/// high (or the first half of each Rate cycle), then keep the last value.
enum class SampleAndHoldMode : int { hold = 0, trackAndHold = 1 };

/// Carried between chunks so splitting a render never changes the signal.
struct SampleAndHoldState {
    bool started = false;
    float held = 0;
    float smoothed = 0;
    float previousTrigger = 0;
    double phase = 0;
};

/// Writes `count` control samples to `output`; `frameOffset` is the absolute frame of `output[0]`. The source is
/// `signal` when it is wired, else the first channel of `audio`, else silence. With a `trigger` wired a bang (rising
/// above 0.5) takes a sample; unwired, a sample is taken `rate` times a second. Before the first sample the value at
/// frame 0 is held. `glideMs` is a one-pole smoother after the hold (0 = off, bit-exact).
void renderSampleAndHold(SampleAndHoldState* state, SampleAndHoldMode mode, const AudioInput& audio,
                         const ControlInput& signal, const ControlInput& trigger, const ParameterSignal& rate,
                         const ParameterSignal& glideMs, double sampleRate, float* output, std::size_t frameOffset,
                         std::size_t count) noexcept;

} // namespace bake::dsp
