#include "BakeDSP/GainVCA.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

void renderGainVCA(GainMode mode, const ParameterSignal& gain, const float* input, const ControlInput& amount,
                   float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (input == nullptr || output == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float source = std::isfinite(input[i]) ? input[i] : 0.0f;
        float multiplier = std::pow(10.0f, gain.valueAt(frame) / 20.0f);
        if (amount.isWired()) {
            const float control = amount.valueAt(frame);
            // VCA: −1…+1 maps to 0…1, so an LFO gives a smooth tremolo. Ring mod keeps the sign.
            multiplier *= mode == GainMode::ringMod ? control : std::clamp((control + 1.0f) * 0.5f, 0.0f, 1.0f);
        }
        const float result = source * multiplier;
        output[i] = std::isfinite(result) ? result : std::copysign(1.0e6f, result);
    }
}

} // namespace bake::dsp
