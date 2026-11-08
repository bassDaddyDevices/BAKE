#include "BakeDSP/Reverse.h"

#include <algorithm>

namespace bake::dsp {

void renderReverse(const float* input, std::size_t inputFrames, float* output,
                   std::size_t frameOffset, std::size_t count,
                   const ParameterSignal& mix) noexcept {
    if (input == nullptr || output == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float dry = input[frame];
        const float reversed = input[inputFrames - 1 - frame];
        const float amount = std::clamp(mix.valueAt(frame), 0.0f, 1.0f);
        output[i] = dry + (reversed - dry) * amount;
    }
}

} // namespace bake::dsp
