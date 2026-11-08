#include "BakeDSP/Math.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr float smallestDivisor = 1e-6f;

float apply(MathOperator op, float a, float b) noexcept {
    switch (op) {
    case MathOperator::add: return a + b;
    case MathOperator::subtract: return a - b;
    case MathOperator::multiply: return a * b;
    case MathOperator::divide: return std::fabs(b) < smallestDivisor ? 0.0f : a / b;
    case MathOperator::absolute: return std::fabs(a);
    case MathOperator::invert: return -a;
    case MathOperator::modulo: return std::fabs(b) < smallestDivisor ? 0.0f : std::fmod(a, b);
    }
    return 0.0f;
}

} // namespace

void renderMath(MathOperator op, const ControlInput& a, const ControlInput& b, const ParameterSignal& scale,
                const ParameterSignal& minimum, const ParameterSignal& maximum,
                float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderMath(op, ParameterSignal(), a, b, scale, minimum, maximum, output, frameOffset, count);
}

void renderMath(MathOperator fixedOp, const ParameterSignal& operatorIndex, const ControlInput& a, const ControlInput& b,
                const ParameterSignal& scale, const ParameterSignal& minimum, const ParameterSignal& maximum,
                float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (output == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float lowValue = minimum.valueAt(frame), highValue = maximum.valueAt(frame);
        const float first = std::isfinite(lowValue) ? lowValue : -16.0f;
        const float second = std::isfinite(highValue) ? highValue : 16.0f;
        const float low = std::min(first, second);
        const float high = std::max(first, second);
        const MathOperator op = choiceAt(operatorIndex, frame, fixedOp, 7);
        const float value = apply(op, a.valueAt(frame), b.valueAt(frame)) * scale.valueAt(frame);
        output[i] = std::isfinite(value) ? std::clamp(value, low, high) : std::clamp(0.0f, low, high);
    }
}

void renderMath(MathOperator op, const ControlInput& a, const ControlInput& b, float scale, float minimum, float maximum,
                float* output, std::size_t frameOffset, std::size_t count) noexcept {
    const auto fixed = [](float value) {
        ParameterSignal signal;
        signal.base = value;
        return signal;
    };
    renderMath(op, a, b, fixed(scale), fixed(minimum), fixed(maximum), output, frameOffset, count);
}

} // namespace bake::dsp
