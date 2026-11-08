#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class MacroCurve : int { linear = 0, exponential, logarithmic };

/// Writes one Macro output. All parameters are read at absolute frames; reversed ranges are allowed.
void renderMacro(const ParameterSignal& value, MacroCurve curve, const ParameterSignal& curveIndex,
                 const ParameterSignal& depth, const ParameterSignal& minimum, const ParameterSignal& maximum,
                 float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
