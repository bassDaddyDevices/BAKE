#include "BakeDSP/Mixer.h"

#include <cmath>

namespace bake::dsp {

void mixInputs(const AudioInput* inputs, std::size_t inputCount, const ParameterSignal& gainDb,
               float* const* outputs, std::size_t channels, std::size_t frameOffset, std::size_t count) noexcept {
    if (outputs == nullptr || (inputs == nullptr && inputCount > 0)) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float gain = std::pow(10.0f, gainDb.valueAt(frame) / 20.0f);
        for (std::size_t channel = 0; channel < channels; ++channel) {
            if (outputs[channel] == nullptr) {
                continue;
            }
            float sum = 0.0f;
            for (std::size_t input = 0; input < inputCount; ++input) {
                sum += inputs[input].spread(channel, frame);
            }
            const float value = sum * gain;
            outputs[channel][i] = std::isfinite(value) ? value : 0.0f;
        }
    }
}

} // namespace bake::dsp
