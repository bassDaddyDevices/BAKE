#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class MathOperator : int { add = 0, subtract, multiply, divide, absolute, invert, modulo };

/// Writes a mono control signal: `operator(a, b) * scale`, held between `minimum` and `maximum`
/// (swapped if given the wrong way round), for absolute frames `frameOffset…+count`. Divide and
/// modulo give 0 where |b| is below 1e-6. Absolute and invert use `a` only; invert is negation.
/// The output is always finite.
void renderMath(MathOperator op, const ControlInput& a, const ControlInput& b, float scale, float minimum, float maximum,
                float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Scale, Clamp Min and Clamp Max as signals, so each can be modulated.
void renderMath(MathOperator op, const ControlInput& a, const ControlInput& b, const ParameterSignal& scale,
                const ParameterSignal& minimum, const ParameterSignal& maximum,
                float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Operator modulatable (an index in MathOperator's order), per sample.
void renderMath(MathOperator op, const ParameterSignal& operatorIndex, const ControlInput& a, const ControlInput& b,
                const ParameterSignal& scale, const ParameterSignal& minimum, const ParameterSignal& maximum,
                float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
