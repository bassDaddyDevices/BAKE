#include "BakeDSP/Channels.h"

namespace bake::dsp {

void copyChannel(const AudioInput& input, std::size_t channel, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (output == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        output[i] = input.sample(channel, frameOffset + i);
    }
}

} // namespace bake::dsp
