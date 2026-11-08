#include "BakeDSP/Gain.h"

namespace bake::dsp {

void applyGain(float* samples, std::size_t count, float gain) noexcept {
    if (samples == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        samples[i] *= gain;
    }
}

} // namespace bake::dsp
