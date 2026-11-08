#include "BakeDSP/Flanger.h"

#include <algorithm>
#include <array>
#include <cmath>

namespace bake::dsp {
namespace {

std::size_t wrapIndex(long long index, std::size_t size) noexcept {
    const long long length = static_cast<long long>(size);
    const long long wrapped = index % length;
    return static_cast<std::size_t>(wrapped < 0 ? wrapped + length : wrapped);
}

float readDelay(const float* line, std::size_t size, double position, FlangerInterpolation interpolation) noexcept {
    const long long base = static_cast<long long>(std::floor(position));
    const double fraction = position - base;
    const double y0 = line[wrapIndex(base - 1, size)];
    const double y1 = line[wrapIndex(base, size)];
    const double y2 = line[wrapIndex(base + 1, size)];
    if (interpolation == FlangerInterpolation::linear) {
        return static_cast<float>(y1 + (y2 - y1) * fraction);
    }
    const double y3 = line[wrapIndex(base + 2, size)];
    const double c0 = y1;
    const double c1 = 0.5 * (y2 - y0);
    const double c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    const double c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    return static_cast<float>(((c3 * fraction + c2) * fraction + c1) * fraction + c0);
}

} // namespace

void renderFlanger(FlangerState* state, const ParameterSignal& delayMs, const ParameterSignal& rateHz,
                   const ParameterSignal& depth, const ParameterSignal& feedback, const ParameterSignal& mix,
                   FlangerPolarity polarity, FlangerInterpolation interpolation, double hfDamping,
                   double sampleRate, float* delayLine, std::size_t delayLineFrames,
                   const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderFlanger(state, delayMs, rateHz, depth, feedback, mix, polarity, interpolation, hfDamping, ParameterSignal(),
                  sampleRate, delayLine, delayLineFrames, input, output, frameOffset, count);
}

void renderFlanger(FlangerState* state, const ParameterSignal& delayMs, const ParameterSignal& rateHz,
                   const ParameterSignal& depth, const ParameterSignal& feedback, const ParameterSignal& mix,
                   FlangerPolarity polarity, FlangerInterpolation interpolation, double hfDamping, const ParameterSignal& hfDampingSignal,
                   double sampleRate, float* delayLine, std::size_t delayLineFrames,
                   const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || delayLine == nullptr || input == nullptr || output == nullptr || delayLineFrames < 8 || !(sampleRate > 0)) {
        return;
    }
    const double fixedDamping = std::clamp(hfDamping, 0.0, 0.95);
    const double polaritySign = polarity == FlangerPolarity::negative ? -1.0 : 1.0;
    const double maxDelaySamples = static_cast<double>(delayLineFrames - 4);

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double dry = std::isfinite(input[i]) ? input[i] : 0.0;
        const double delay = std::clamp(static_cast<double>(delayMs.valueAt(frame)) * sampleRate / 1'000.0, 1.0, maxDelaySamples);
        const double frequency = std::clamp(static_cast<double>(rateHz.valueAt(frame)), 0.01, 20.0);
        const double excursion = std::clamp(static_cast<double>(depth.valueAt(frame)), 0.0, 1.0);
        state->phase += 2.0 * 3.14159265358979323846 * frequency / sampleRate;
        if (state->phase >= 2.0 * 3.14159265358979323846) {
            state->phase -= 2.0 * 3.14159265358979323846;
        }
        const double phase = state->phase;
        const double lfo = 0.5 + 0.5 * std::sin(phase);
        // Read before this sample is written: cubic reads taps up to base + 2, so it needs at least
        // 2 samples of delay (linear 1) to never touch the slot about to be overwritten.
        const double minimumDelay = interpolation == FlangerInterpolation::cubic ? 2.0 : 1.0;
        const double readDelaySamples = std::clamp(delay * (1.0 - excursion * lfo), minimumDelay, maxDelaySamples);
        const std::size_t writeIndex = frame % delayLineFrames;
        const double readPosition = static_cast<double>(writeIndex) - readDelaySamples;
        const double delayed = readDelay(delayLine, delayLineFrames, readPosition, interpolation);
        const double damping = hfDampingSignal.modulation == nullptr
            ? fixedDamping : std::clamp(static_cast<double>(hfDampingSignal.valueAt(frame)), 0.0, 0.95);
        state->dampedFeedback = delayed * (1.0 - damping) + state->dampedFeedback * damping;
        const double gain = std::clamp(static_cast<double>(feedback.valueAt(frame)), 0.0, 0.95) * polaritySign;
        const double writeSample = std::clamp(dry + gain * state->dampedFeedback, -1.0e6, 1.0e6);
        delayLine[writeIndex] = static_cast<float>(writeSample);
        const double wet = dry + delayed;
        const double blend = std::clamp(static_cast<double>(mix.valueAt(frame)), 0.0, 1.0);
        const double result = std::clamp(dry + (wet - dry) * blend, -1.0e6, 1.0e6);
        output[i] = static_cast<float>(result);
    }
}

// MARK: Through-zero

namespace {

/// The whole channel with silence outside it.
double sampleAt(const float* data, std::size_t frames, long long index) noexcept {
    if (index < 0 || index >= static_cast<long long>(frames)) {
        return 0.0;
    }
    const double value = data[index];
    return std::isfinite(value) ? value : 0.0;
}

double readWhole(const float* data, std::size_t frames, double position, FlangerInterpolation interpolation) noexcept {
    const long long base = static_cast<long long>(std::floor(position));
    const double fraction = position - static_cast<double>(base);
    const double y1 = sampleAt(data, frames, base);
    const double y2 = sampleAt(data, frames, base + 1);
    if (interpolation == FlangerInterpolation::linear) {
        return y1 + (y2 - y1) * fraction;
    }
    const double y0 = sampleAt(data, frames, base - 1);
    const double y3 = sampleAt(data, frames, base + 2);
    const double c1 = 0.5 * (y2 - y0);
    const double c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    const double c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    return ((c3 * fraction + c2) * fraction + c1) * fraction + y1;
}

} // namespace

std::size_t flangerHistoryFrames(double sampleRate, double maxMs) noexcept {
    return static_cast<std::size_t>(std::ceil(sampleRate * maxMs / 1'000.0)) + 8;
}

int flangerDispersionSections(double amount) noexcept {
    return static_cast<int>(std::lround(std::clamp(amount, 0.0, 1.0) * flangerMaxDispersionSections));
}

double flangerDispersionDelay(int sections) noexcept {
    const double a = flangerDispersionCoefficient;
    return std::max(sections, 0) * (1.0 - a) / (1.0 + a);
}

void renderFlangerDispersion(const float* input, std::size_t frames, float* output, int sections) noexcept {
    if (input == nullptr || output == nullptr) {
        return;
    }
    const int count = std::clamp(sections, 0, flangerMaxDispersionSections);
    const double a = flangerDispersionCoefficient;
    std::array<double, flangerMaxDispersionSections> memory{};
    for (std::size_t i = 0; i < frames; ++i) {
        double value = std::isfinite(input[i]) ? input[i] : 0.0;
        for (int section = 0; section < count; ++section) {
            // H(z) = (a + z^-1) / (1 + a z^-1), transposed direct form II.
            const double result = a * value + memory[static_cast<std::size_t>(section)];
            memory[static_cast<std::size_t>(section)] = value - a * result;
            value = result;
        }
        output[i] = static_cast<float>(value);
    }
}

void renderFlangerThroughZero(FlangerState* state, const FlangerThroughZero& controls,
                              const float* dry, const float* wet, std::size_t frames,
                              float* history, std::size_t historyFrames,
                              float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || dry == nullptr || wet == nullptr || history == nullptr || output == nullptr
        || historyFrames < 8 || !(controls.sampleRate > 0)) {
        return;
    }
    constexpr double twoPi = 2.0 * 3.14159265358979323846;
    const double sampleRate = controls.sampleRate;
    const double fixedDamping = std::clamp(controls.hfDamping, 0.0, 0.95);
    const double feedbackSign = controls.feedbackPolarity == FlangerPolarity::negative ? -1.0 : 1.0;
    const double wetSign = controls.wetPolarity == FlangerWetPolarity::negative ? -1.0 : 1.0;
    const double maxSamples = static_cast<double>(historyFrames - 4);
    // The history read can't touch the slot being written: cubic reads up to two ahead of its base.
    const double minimumTap = controls.interpolation == FlangerInterpolation::cubic ? 2.0 : 1.0;

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double dryValue = sampleAt(dry, frames, static_cast<long long>(frame));
        const double delay = std::clamp(static_cast<double>(controls.delayMs.valueAt(frame)) * sampleRate / 1'000.0, 0.0, maxSamples);
        const double frequency = std::clamp(static_cast<double>(controls.rateHz.valueAt(frame)), 0.01, 20.0);
        const double excursion = std::clamp(static_cast<double>(controls.depth.valueAt(frame)), 0.0, 1.0);
        state->phase += twoPi * frequency / sampleRate;
        if (state->phase >= twoPi) {
            state->phase -= twoPi;
        }
        const double lfo = 0.5 + 0.5 * std::sin(state->phase);
        // Positive: behind the input. Negative: ahead of it. Zero crossing when depth × lfo reaches one half.
        const double distance = delay * (1.0 - 2.0 * excursion * lfo);
        const double position = static_cast<double>(frame) - distance + controls.lookaheadSamples;
        const double tapped = readWhole(wet, frames, position, controls.interpolation);

        const std::size_t writeIndex = frame % historyFrames;
        const double tap = std::clamp(std::abs(distance), minimumTap, maxSamples);
        const double recirculated = readDelay(history, historyFrames, static_cast<double>(writeIndex) - tap, controls.interpolation);
        const double damping = controls.hfDampingSignal.modulation == nullptr
            ? fixedDamping : std::clamp(static_cast<double>(controls.hfDampingSignal.valueAt(frame)), 0.0, 0.95);
        state->dampedFeedback = recirculated * (1.0 - damping) + state->dampedFeedback * damping;
        const double gain = std::clamp(static_cast<double>(controls.feedback.valueAt(frame)), 0.0, 0.95) * feedbackSign;
        const double combined = std::clamp(tapped + gain * state->dampedFeedback, -1.0e6, 1.0e6);
        history[writeIndex] = static_cast<float>(combined);

        const double blend = std::clamp(static_cast<double>(controls.mix.valueAt(frame)), 0.0, 1.0);
        output[i] = static_cast<float>(std::clamp(dryValue + blend * wetSign * combined, -1.0e6, 1.0e6));
    }
}

} // namespace bake::dsp
