#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class FeedbackMode : int { tanh = 0, tape, hard, crush };

/// One channel's carried state for the return-path damping filters.
struct FeedbackState {
    double highpassInput = 0;
    double highpassOutput = 0;
    double lowpassOutput = 0;
};

/// Adds a delayed, damped and saturated return to one channel of the input. Input buffers use
/// absolute frame indices; output points at `frameOffset` and receives `count` samples.
void renderFeedback(FeedbackState* state, const AudioInput& input, const AudioInput& returned,
                    int channel, FeedbackMode fixedMode, const ParameterSignal& gain, const ParameterSignal& drive,
                    const ParameterSignal& modeIndex, const ParameterSignal& lowCut,
                    const ParameterSignal& highCut, double sampleRate, int delayFrames,
                    float* output, int frameOffset, int count) noexcept;

} // namespace bake::dsp
