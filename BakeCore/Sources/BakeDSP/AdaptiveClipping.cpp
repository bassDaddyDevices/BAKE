#include "BakeDSP/AdaptiveClipping.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr double attackSeconds = 0.0005;

int factorOf(int oversampling) noexcept { return clampOversampling(std::max(oversampling, 1)); }

/// Moves the envelope to base frame `frame` (frames arrive in increasing order, each once) and
/// caches that frame's ceiling and knee.
void advance(AdaptiveClippingState& s, const AdaptiveClippingControls& c, const float* input,
             std::size_t inputFrames, std::size_t frame) noexcept {
    if (s.cached && s.cachedFrame == frame) {
        return;
    }
    const double rate = c.sampleRate;
    const double level = frame < inputFrames ? std::abs(static_cast<double>(input[frame])) : 0.0;
    const double attack = std::exp(-1 / (attackSeconds * rate));
    const double release = std::exp(-1 / (c.release.valueAt(frame) * 0.001 * rate));
    const double coefficient = level > s.envelope ? attack : release;
    s.envelope = coefficient * s.envelope + (1 - coefficient) * level;
    s.ceiling = std::max(s.envelope * std::pow(10.0, c.threshold.valueAt(frame) / 20),
                         std::pow(10.0, c.floor.valueAt(frame) / 20));
    s.knee = choiceAt(c.kneeIndex, frame, c.knee, 2);
    s.cached = true;
    s.cachedFrame = frame;
}

} // namespace

std::size_t adaptiveClippingScratchFloats(int oversampling, std::size_t maxCount) noexcept {
    const int factor = factorOf(oversampling);
    return factor < 2 ? 0 : oversamplingScratchFloats(factor, maxCount);
}

std::size_t adaptiveClippingHistoryFloats(int oversampling) noexcept {
    const int factor = factorOf(oversampling);
    return factor < 2 ? 0 : oversampledHistoryFloats(factor);
}

std::size_t adaptiveClippingCeilingScratchDoubles(std::size_t frames) noexcept {
    return 2 * frames + 1;
}

void buildAdaptiveClippingCeilings(const AdaptiveClippingControls& c, const float* input, std::size_t inputFrames,
                                   std::size_t frames, double* ceilings, double* scratch) noexcept {
    if (input == nullptr || ceilings == nullptr || scratch == nullptr || frames == 0) {
        return;
    }
    const double rate = c.sampleRate;
    const double attack = std::exp(-1 / (attackSeconds * rate));
    double* envelope = scratch;
    double* queue = scratch + frames; // indices of a falling run of envelope values, oldest first
    double follower = 0;
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const double level = frame < inputFrames ? std::abs(static_cast<double>(input[frame])) : 0.0;
        const double release = std::exp(-1 / (c.release.valueAt(frame) * 0.001 * rate));
        const double coefficient = level > follower ? attack : release;
        follower = coefficient * follower + (1 - coefficient) * level;
        envelope[frame] = follower;
    }
    const std::size_t ahead = static_cast<std::size_t>(std::lround(std::max(c.lookaheadMilliseconds, 0.0) * 0.001 * rate));
    std::size_t head = 0, tail = 0, next = 0; // queue[head …< tail]; `next` is the next frame to add
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const std::size_t last = std::min(frame + ahead, frames - 1);
        for (; next <= last; ++next) {
            while (tail > head && envelope[static_cast<std::size_t>(queue[tail - 1])] <= envelope[next]) {
                --tail;
            }
            queue[tail++] = static_cast<double>(next);
        }
        while (static_cast<std::size_t>(queue[head]) < frame) {
            ++head;
        }
        const double peak = envelope[static_cast<std::size_t>(queue[head])];
        ceilings[frame] = std::max(peak * std::pow(10.0, c.threshold.valueAt(frame) / 20),
                                   std::pow(10.0, c.floor.valueAt(frame) / 20));
    }
}

void renderAdaptiveClippingAhead(const AdaptiveClippingControls& c, const float* input, std::size_t inputFrames,
                                 const double* ceilings, std::size_t ceilingFrames,
                                 float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept {
    if (input == nullptr || output == nullptr || ceilings == nullptr || ceilingFrames == 0 || count == 0) {
        return;
    }
    const auto clip = [&c, ceilings, ceilingFrames](float x, std::size_t frame) {
        const double ceiling = ceilings[std::min(frame, ceilingFrames - 1)];
        const auto knee = choiceAt(c.kneeIndex, frame, c.knee, 2);
        const double y = knee == AdaptiveClippingKnee::hard
            ? std::clamp(static_cast<double>(x), -ceiling, ceiling)
            : ceiling * std::tanh(x / ceiling);
        return static_cast<float>(y);
    };
    const int factor = factorOf(c.oversampling);
    if (factor < 2) {
        for (std::size_t i = 0; i < count; ++i) {
            const std::size_t frame = frameOffset + i;
            output[i] = clip(frame < inputFrames ? input[frame] : 0.0f, frame);
        }
    } else {
        renderOversampled(factor, input, inputFrames, output, frameOffset, count, scratch, clip);
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float makeup = static_cast<float>(std::pow(10.0, c.makeup.valueAt(frame) / 20));
        const float mix = c.mix.valueAt(frame);
        const float dry = frame < inputFrames ? input[frame] : 0.0f;
        const float value = mix * makeup * output[i] + (1 - mix) * dry;
        output[i] = std::isfinite(value) ? value : 0.0f;
    }
}

void renderAdaptiveClipping(AdaptiveClippingState* state, const AdaptiveClippingControls& controls,
                            const float* input, std::size_t inputFrames,
                            float* output, std::size_t frameOffset, std::size_t count,
                            float* scratch, float* history) noexcept {
    if (state == nullptr || input == nullptr || output == nullptr || count == 0) {
        return;
    }
    renderOversampledStateful(factorOf(controls.oversampling), input, inputFrames, output, frameOffset, count,
                              scratch, history, state->stream, *state,
                              [&controls, input, inputFrames](float x, std::size_t frame, AdaptiveClippingState& s) {
                                  advance(s, controls, input, inputFrames, frame);
                                  const double c = s.ceiling;
                                  const double y = s.knee == AdaptiveClippingKnee::hard
                                      ? std::clamp(static_cast<double>(x), -c, c)
                                      : c * std::tanh(x / c);
                                  return static_cast<float>(y);
                              });
    // Makeup and Mix at the base rate against the untouched input, so Mix 0 is exact.
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float makeup = static_cast<float>(std::pow(10.0, controls.makeup.valueAt(frame) / 20));
        const float mix = controls.mix.valueAt(frame);
        const float dry = frame < inputFrames ? input[frame] : 0.0f;
        const float value = mix * makeup * output[i] + (1 - mix) * dry;
        output[i] = std::isfinite(value) ? value : 0.0f;
    }
}

} // namespace bake::dsp
