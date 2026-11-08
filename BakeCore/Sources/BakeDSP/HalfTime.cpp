#include "BakeDSP/HalfTime.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

void renderHalfTime(HalfTimeState* state, HalfTimeMode mode, const ParameterSignal& speed, const ParameterSignal& mix,
                    double windowFrames, double smoothFrames, int grainFrames, const ControlInput& sync,
                    const float* input, std::size_t inputFrames, float* output, std::size_t frameOffset,
                    std::size_t count) noexcept {
    renderHalfTime(state, mode, speed, mix, windowFrames, smoothFrames, grainFrames, HalfTimeModulation(), sync,
                   input, inputFrames, output, frameOffset, count);
}

void renderHalfTime(HalfTimeState* state, HalfTimeMode mode, const ParameterSignal& speed, const ParameterSignal& mix,
                    double windowFrames, double smoothFrames, int grainFrames, const HalfTimeModulation& modulation,
                    const ControlInput& sync, const float* input, std::size_t inputFrames, float* output,
                    std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || output == nullptr) {
        return;
    }
    const double window = std::max(windowFrames, 1.0);
    // Even, so two Hann windows half a grain apart sum to 1.
    const int grain = std::max(grainFrames / 2, 1) * 2;
    const int hop = grain / 2;
    const bool granular = mode == HalfTimeMode::granular;
    const double rate = std::max(modulation.sampleRate, 1.0);
    const auto toFrames = [rate](double milliseconds) { return std::max(milliseconds, 0.0) / 1000 * rate; };
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const auto now = static_cast<double>(frame);
        if (!state->started) {
            state->started = true;
            state->windowStart = now;
            state->path.position = now;
            state->path.oldPosition = now;
        }

        bool startWindow;
        if (sync.isWired()) {
            const float value = sync.valueAt(frame);
            startWindow = value > 0.5f && state->previousSync <= 0.5f;
            state->previousSync = value;
        } else {
            startWindow = now - state->windowStart >= modulatedOr(modulation.window, frame, window, [&](double ms) { return std::max(toFrames(ms), 1.0); });
        }
        if (startWindow) {
            state->windowStart = now;
            // Granular's grains already overlap across the jump, so it cuts.
            state->path.jump(now, granular ? 0 : modulatedOr(modulation.smooth, frame, smoothFrames, toFrames));
        }

        float wet;
        if (granular && modulation.grain.modulation != nullptr) {
            // Each grain takes Grain as it launches; the next launches half of it later.
            if (now >= state->nextLaunch) {
                const int length = std::max(static_cast<int>(std::lround(toFrames(modulation.grain.valueAt(frame)) / 2)), 1) * 2;
                state->grains.launch(input, inputFrames, state->path.position, length);
                state->nextLaunch = now + length / 2;
            }
            wet = state->grains.read(input, inputFrames, grain, true);
        } else if (granular) {
            if (frame % static_cast<std::size_t>(hop) == 0) {
                state->grains.launch(input, inputFrames, state->path.position, grain);
            }
            wet = state->grains.read(input, inputFrames, grain);
        } else {
            wet = state->path.read(input, inputFrames);
        }
        state->path.advance(std::clamp(static_cast<double>(speed.valueAt(frame)), 0.001, 1.0));

        const float dry = frame < inputFrames && std::isfinite(input[frame]) ? input[frame] : 0.0f;
        const float amount = std::clamp(mix.valueAt(frame), 0.0f, 1.0f);
        output[i] = dry + (wet - dry) * amount;
    }
}

} // namespace bake::dsp
