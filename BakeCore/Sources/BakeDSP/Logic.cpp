#include "BakeDSP/Logic.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

/// A plain comparator when `margin` is 0 (high iff above the threshold); a Schmitt trigger otherwise.
bool compare(bool& isHigh, float value, float threshold, float margin) noexcept {
    if (margin <= 0.0f) {
        isHigh = value > threshold;
    } else if (value > threshold + margin) {
        isHigh = true;
    } else if (value < threshold - margin) {
        isHigh = false;
    }
    return isHigh;
}

} // namespace

void renderLogic(LogicState* state, LogicOperator op, const ControlInput& a, const ControlInput& b,
                 const ParameterSignal& threshold, float hysteresis, std::size_t holdFrames,
                 float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderLogic(state, op, a, b, threshold, hysteresis, holdFrames, ParameterSignal(), ParameterSignal(), 48000, output, frameOffset, count);
}

void renderLogic(LogicState* state, LogicOperator op, const ControlInput& a, const ControlInput& b,
                 const ParameterSignal& threshold, float hysteresis, std::size_t holdFrames,
                 const ParameterSignal& hysteresisSignal, const ParameterSignal& holdSeconds, double sampleRate,
                 float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderLogic(state, op, ParameterSignal(), a, b, threshold, hysteresis, holdFrames, hysteresisSignal, holdSeconds,
                sampleRate, output, frameOffset, count);
}

void renderLogic(LogicState* state, LogicOperator fixedOp, const ParameterSignal& operatorIndex, const ControlInput& a,
                 const ControlInput& b, const ParameterSignal& threshold, float hysteresis, std::size_t holdFrames,
                 const ParameterSignal& hysteresisSignal, const ParameterSignal& holdSeconds, double sampleRate,
                 float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || output == nullptr) {
        return;
    }
    const float fixedMargin = std::isfinite(hysteresis) ? std::max(hysteresis, 0.0f) : 0.0f;
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const LogicOperator op = choiceAt(operatorIndex, frame, fixedOp, 5);
        const bool usesB = op == LogicOperator::andGate || op == LogicOperator::orGate || op == LogicOperator::xorGate;
        const float margin = hysteresisSignal.modulation == nullptr
            ? fixedMargin : std::max(hysteresisSignal.valueAt(frame), 0.0f);
        const float level = threshold.valueAt(frame);
        const bool high = compare(state->aIsHigh, a.valueAt(frame), level, margin);
        const bool other = usesB ? compare(state->bIsHigh, b.valueAt(frame), level, margin) : false;
        bool gate = high;
        switch (op) {
        case LogicOperator::threshold: break;
        case LogicOperator::andGate: gate = high && other; break;
        case LogicOperator::orGate: gate = high || other; break;
        case LogicOperator::xorGate: gate = high != other; break;
        case LogicOperator::notGate: gate = !high; break;
        }
        if (gate) {
            state->holdRemaining = holdSeconds.modulation == nullptr
                ? holdFrames : static_cast<std::size_t>(std::llround(std::max(static_cast<double>(holdSeconds.valueAt(frame)), 0.0) * sampleRate));
        } else if (state->holdRemaining > 0) {
            --state->holdRemaining;
            gate = true;
        }
        output[i] = gate ? 1.0f : 0.0f;
    }
}

} // namespace bake::dsp
