#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class EnvelopeFollowerDetection : int { peak = 0, rms = 1 };

struct EnvelopeFollowerState {
    double level = 0;
    double channelPower[maxAudioInputChannels] = {};
};

/// Follow the loudest channel's peak or RMS level and write a mono 0…1 control signal. Attack and
/// Release are in milliseconds (the catalog's unit); Gain, in dB, scales the detected level once.
void renderEnvelopeFollower(EnvelopeFollowerState* state, EnvelopeFollowerDetection detection,
                            const AudioInput& input, const ParameterSignal& attack,
                            const ParameterSignal& release, const ParameterSignal& gain,
                            double sampleRate, float* output, std::size_t frameOffset,
                            std::size_t count) noexcept;

} // namespace bake::dsp
