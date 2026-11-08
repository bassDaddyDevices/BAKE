#include "BakeDSP/MidSide.h"

namespace bake::dsp {

void encodeMidSide(const AudioInput& input, float* mid, float* side, std::size_t frameOffset, std::size_t count) noexcept {
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float left = input.sample(0, frame);
        const float right = input.spread(1, frame);
        if (mid != nullptr) {
            mid[i] = (left + right) * 0.5f;
        }
        if (side != nullptr) {
            side[i] = (left - right) * 0.5f;
        }
    }
}

void decodeMidSide(const AudioInput& mid, const AudioInput& side, float* left, float* right,
                   std::size_t frameOffset, std::size_t count) noexcept {
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float m = mid.sample(0, frame);
        const float s = side.sample(0, frame);
        if (left != nullptr) {
            left[i] = m + s;
        }
        if (right != nullptr) {
            right[i] = m - s;
        }
    }
}

} // namespace bake::dsp
