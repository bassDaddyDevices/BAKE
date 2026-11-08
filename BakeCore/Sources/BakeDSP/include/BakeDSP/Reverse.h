#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// Reverse a full channel into output. The operation is stateless and supports arbitrary chunks.
void renderReverse(const float* input, std::size_t inputFrames, float* output,
                   std::size_t frameOffset, std::size_t count,
                   const ParameterSignal& mix) noexcept;

} // namespace bake::dsp
