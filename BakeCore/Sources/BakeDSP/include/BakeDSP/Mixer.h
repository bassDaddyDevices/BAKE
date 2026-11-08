#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// Sums `inputs` (in order; mono inputs feed every channel, short ones are silent past their end)
/// into `channels` output buffers, then applies `gainDb`.
void mixInputs(const AudioInput* inputs, std::size_t inputCount, const ParameterSignal& gainDb,
               float* const* outputs, std::size_t channels, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
