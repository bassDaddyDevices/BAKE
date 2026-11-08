#include "BakeDSP/Join.h"

#include <cmath>

namespace bake::dsp {

namespace {
constexpr double pi = 3.14159265358979323846;
}

void joinRender(const AudioInput* inputs, std::size_t count, const std::size_t* starts, const std::size_t* holds,
                float* const* outputs, std::size_t channels, std::size_t first, std::size_t frameCount) noexcept {
    if (outputs == nullptr) return;
    for (std::size_t i = 0; i < frameCount; ++i) {
        const std::size_t frame = first + i;
        for (std::size_t channel = 0; channel < channels; ++channel) {
            if (outputs[channel] == nullptr) continue;
            double sum = 0.0;
            for (std::size_t k = 0; k < count; ++k) {
                const std::size_t length = inputs[k].frames;
                if (frame < starts[k] || frame >= starts[k] + length) continue;
                const std::size_t j = frame - starts[k];
                const std::size_t in = k > 0 ? holds[k - 1] : 0;  // overlapping the previous input's end
                const std::size_t out = holds[k];                  // overlapping the next input's start
                double gain = 1.0;
                if (j < in) {
                    gain = std::sin(pi / 2 * (static_cast<double>(j) + 0.5) / static_cast<double>(in));
                } else if (out > 0 && j >= length - out) {
                    gain = std::cos(pi / 2 * (static_cast<double>(j - (length - out)) + 0.5) / static_cast<double>(out));
                }
                sum += static_cast<double>(inputs[k].spread(channel, j)) * gain;
            }
            outputs[channel][i] = std::isfinite(sum) ? static_cast<float>(sum) : 0.0f;
        }
    }
}

} // namespace bake::dsp
