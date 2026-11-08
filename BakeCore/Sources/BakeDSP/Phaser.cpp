#include "BakeDSP/Phaser.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

float finiteOrZero(float value) noexcept {
    return std::isfinite(value) ? value : 0.0f;
}

double allPass(double input, double coefficient, double& memory) noexcept {
    const double output = -coefficient * input + memory;
    memory = input + coefficient * output;
    return output;
}

} // namespace

void renderPhaser(PhaserState* state, PhaserChannel channel, int stages,
                  const ParameterSignal& center, const ParameterSignal& width,
                  const ParameterSignal& rate, const ParameterSignal& depth,
                  const ParameterSignal& feedback, const ParameterSignal& mix,
                  double sampleRate, double stereoOffset,
                  const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderPhaser(state, channel, stages, center, width, rate, depth, feedback, mix, sampleRate, stereoOffset,
                 ParameterSignal(), input, output, frameOffset, count);
}

void renderPhaser(PhaserState* state, PhaserChannel channel, int stages,
                  const ParameterSignal& center, const ParameterSignal& width,
                  const ParameterSignal& rate, const ParameterSignal& depth,
                  const ParameterSignal& feedback, const ParameterSignal& mix,
                  double sampleRate, double stereoOffset, const ParameterSignal& stereoOffsetSignal,
                  const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || input == nullptr || output == nullptr || !(sampleRate > 0)) {
        return;
    }
    const int stageCount = std::clamp(stages, 2, maxPhaserStages);
    const double fixedChannelOffset = channel == PhaserChannel::right ? std::clamp(stereoOffset, 0.0, 1.0) : 0.0;
    constexpr double pi = 3.14159265358979323846;

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double channelOffset = stereoOffsetSignal.modulation == nullptr || channel != PhaserChannel::right
            ? fixedChannelOffset : std::clamp(static_cast<double>(stereoOffsetSignal.valueAt(frame)), 0.0, 1.0);
        const double dry = finiteOrZero(input[i]);
        const double octaveWidth = std::clamp(static_cast<double>(width.valueAt(frame)), 0.25, 4.0);
        // The sweep moves the centre by up to ±depth · width/2 octaves.
        const double sweep = std::clamp(static_cast<double>(depth.valueAt(frame)), 0.0, 1.0)
            * std::sin(2.0 * pi * state->sweepPhase) * octaveWidth * 0.5;
        state->sweepPhase += std::clamp(static_cast<double>(rate.valueAt(frame)), 0.01, 20.0) / sampleRate;
        state->sweepPhase -= std::floor(state->sweepPhase);
        const double centerHz = std::clamp(static_cast<double>(center.valueAt(frame)) * std::pow(2.0, channelOffset + sweep), 20.0, sampleRate * 0.45);
        const double resonance = std::clamp(static_cast<double>(feedback.valueAt(frame)), -0.95, 0.95);
        // Feedback goes back into the stages (deepening the notches), through a DC blocker: an
        // all-pass passes DC unchanged, so without it the loop would boost the bass by 1/(1 − r).
        const double fed = state->previousFeedback - state->dcInput + 0.995 * state->dcOutput;
        state->dcInput = state->previousFeedback;
        state->dcOutput = fed;
        double wet = dry + resonance * fed;
        for (int stage = 0; stage < stageCount; ++stage) {
            const double position = static_cast<double>(stage) / (stageCount - 1);
            const double frequency = centerHz * std::pow(2.0, (position - 0.5) * octaveWidth);
            const double clampedFrequency = std::clamp(frequency, 10.0, sampleRate * 0.45);
            const double tangent = std::tan(pi * clampedFrequency / sampleRate);
            const double coefficient = (1.0 - tangent) / (1.0 + tangent);
            wet = allPass(wet, coefficient, state->z[stage]);
        }
        state->previousFeedback = wet;
        const double blend = std::clamp(static_cast<double>(mix.valueAt(frame)), 0.0, 1.0);
        const double result = dry + (wet - dry) * blend;
        output[i] = std::isfinite(result) ? static_cast<float>(result) : 0.0f;
    }
}

// MARK: Deep phaser

namespace {

double inputAt(const float* data, std::size_t frames, std::size_t index) noexcept {
    return index < frames ? static_cast<double>(finiteOrZero(data[index])) : 0.0;
}

} // namespace

std::size_t phaserTransientCapacity(std::size_t frames, double sampleRate) noexcept {
    const auto gap = std::max<std::size_t>(static_cast<std::size_t>(0.08 * sampleRate), 1);
    return frames / gap + 2;
}

std::size_t detectPhaserTransients(const float* const* channels, std::size_t channelCount, std::size_t frames,
                                   double sampleRate, double sensitivity,
                                   std::int32_t* onsets, std::size_t capacity) noexcept {
    if (channels == nullptr || channelCount == 0 || onsets == nullptr || capacity == 0 || !(sampleRate > 0)) {
        return 0;
    }
    const double fastCoefficient = std::exp(-1.0 / (0.001 * sampleRate));
    const double slowCoefficient = std::exp(-1.0 / (0.030 * sampleRate));
    const double ratio = 1.5 + 6.0 * (1.0 - std::clamp(sensitivity, 0.0, 1.0));
    const auto gap = std::max<std::size_t>(static_cast<std::size_t>(0.08 * sampleRate), 1);
    const auto lead = static_cast<std::size_t>(0.001 * sampleRate);
    const auto magnitudeAt = [&](std::size_t frame) {
        double sum = 0.0;
        for (std::size_t channel = 0; channel < channelCount; ++channel) {
            sum += channels[channel] == nullptr ? 0.0 : static_cast<double>(finiteOrZero(channels[channel][frame]));
        }
        return std::abs(sum / static_cast<double>(channelCount));
    };

    // The quietest hits worth catching are a few percent of the loudest one.
    double fast = 0.0;
    double peak = 0.0;
    for (std::size_t i = 0; i < frames; ++i) {
        fast = fastCoefficient * fast + (1.0 - fastCoefficient) * magnitudeAt(i);
        peak = std::max(peak, fast);
    }
    const double floorLevel = 0.03 * peak;

    fast = 0.0;
    double slow = 0.0;
    std::size_t count = 0;
    bool hasOnset = false;
    std::size_t last = 0;
    for (std::size_t i = 0; i < frames && count < capacity; ++i) {
        const double magnitude = magnitudeAt(i);
        fast = fastCoefficient * fast + (1.0 - fastCoefficient) * magnitude;
        slow = slowCoefficient * slow + (1.0 - slowCoefficient) * magnitude;
        if (fast > floorLevel && fast > ratio * slow && (!hasOnset || i - last >= gap)) {
            onsets[count++] = static_cast<std::int32_t>(i > lead ? i - lead : 0);
            hasOnset = true;
            last = i;
        }
    }
    return count;
}

void buildPhaserSweep(const ParameterSignal& rate, double sampleRate, std::size_t frames,
                      const std::int32_t* onsets, std::size_t onsetCount, double startPhase, float* sweepPhase) noexcept {
    if (sweepPhase == nullptr || !(sampleRate > 0)) {
        return;
    }
    double phase = 0.0;
    std::size_t next = 0;
    const double start = startPhase - std::floor(startPhase);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        while (onsets != nullptr && next < onsetCount && static_cast<std::size_t>(onsets[next]) <= frame) {
            phase = start;
            ++next;
        }
        sweepPhase[frame] = static_cast<float>(phase);
        phase += std::clamp(static_cast<double>(rate.valueAt(frame)), 0.01, 20.0) / sampleRate;
        phase -= std::floor(phase);
    }
}

void renderPhaserDeep(PhaserDeepState* state, PhaserChannel channel, int stages,
                      const ParameterSignal& center, const ParameterSignal& width, const ParameterSignal& depth,
                      const ParameterSignal& feedback, double sampleRate, double stereoOffset,
                      const ParameterSignal& stereoOffsetSignal, const float* sweepPhase,
                      const float* input, std::size_t frames,
                      float* output, std::size_t outputBase, std::size_t first, std::size_t count, bool reverse) noexcept {
    if (state == nullptr || sweepPhase == nullptr || input == nullptr || output == nullptr || frames == 0 || !(sampleRate > 0)) {
        return;
    }
    const int stageCount = std::clamp(stages, 2, maxPhaserDeepStages);
    const double fixedChannelOffset = channel == PhaserChannel::right ? std::clamp(stereoOffset, 0.0, 1.0) : 0.0;
    constexpr double pi = 3.14159265358979323846;

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = reverse ? first + count - 1 - i : first + i;
        const long long block = static_cast<long long>(frame / phaserDeepHop);
        if (block != state->block) {
            // One set of coefficients per block, from the signals at its middle: the same for either direction.
            state->block = block;
            const std::size_t middle = std::min(static_cast<std::size_t>(block) * phaserDeepHop + phaserDeepHop / 2, frames - 1);
            const double channelOffset = stereoOffsetSignal.modulation == nullptr || channel != PhaserChannel::right
                ? fixedChannelOffset : std::clamp(static_cast<double>(stereoOffsetSignal.valueAt(middle)), 0.0, 1.0);
            const double octaveWidth = std::clamp(static_cast<double>(width.valueAt(middle)), 0.25, 4.0);
            const double sweep = std::clamp(static_cast<double>(depth.valueAt(middle)), 0.0, 1.0)
                * std::sin(2.0 * pi * static_cast<double>(sweepPhase[middle])) * octaveWidth * 0.5;
            const double centerHz = std::clamp(static_cast<double>(center.valueAt(middle)) * std::pow(2.0, channelOffset + sweep),
                                               20.0, sampleRate * 0.45);
            for (int stage = 0; stage < stageCount; ++stage) {
                const double position = static_cast<double>(stage) / (stageCount - 1);
                const double frequency = std::clamp(centerHz * std::pow(2.0, (position - 0.5) * octaveWidth), 10.0, sampleRate * 0.45);
                const double tangent = std::tan(pi * frequency / sampleRate);
                state->coefficient[stage] = (1.0 - tangent) / (1.0 + tangent);
            }
        }
        const double dry = inputAt(input, frames, frame);
        const double resonance = std::clamp(static_cast<double>(feedback.valueAt(frame)), -0.95, 0.95);
        // Same DC-blocked feedback as the classic phaser.
        const double fed = state->previousFeedback - state->dcInput + 0.995 * state->dcOutput;
        state->dcInput = state->previousFeedback;
        state->dcOutput = fed;
        double wet = dry + resonance * fed;
        for (int stage = 0; stage < stageCount; ++stage) {
            wet = allPass(wet, state->coefficient[stage], state->z[stage]);
        }
        state->previousFeedback = wet;
        output[frame - outputBase] = std::isfinite(wet) ? static_cast<float>(wet) : 0.0f;
    }
}

void renderPhaserDeepBlend(PhaserDirection direction, const ParameterSignal& mix,
                           const float* dry, std::size_t frames,
                           const float* forwardWet, const float* backwardWet,
                           float* output, std::size_t first, std::size_t count) noexcept {
    if (dry == nullptr || output == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = first + i;
        const double dryValue = inputAt(dry, frames, frame);
        const double forward = forwardWet != nullptr ? static_cast<double>(forwardWet[i]) : 0.0;
        const double backward = backwardWet != nullptr && frame < frames ? static_cast<double>(backwardWet[frame]) : 0.0;
        const double wet = direction == PhaserDirection::forward ? forward
            : direction == PhaserDirection::backward ? backward : 0.5 * (forward + backward);
        const double blend = std::clamp(static_cast<double>(mix.valueAt(frame)), 0.0, 1.0);
        const double result = dryValue + (wet - dryValue) * blend;
        output[i] = std::isfinite(result) ? static_cast<float>(result) : 0.0f;
    }
}

} // namespace bake::dsp
