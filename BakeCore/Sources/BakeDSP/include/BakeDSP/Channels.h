#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"

namespace bake::dsp {

/// Writes channel `channel` of `input` for absolute frames `frameOffset…+count` into `output`
/// (silence where the input has no such channel or has ended). Splitter and Merger both use it.
void copyChannel(const AudioInput& input, std::size_t channel, float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
