#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"

namespace bake::dsp {

/// Mid = (L + R) / 2 and Side = (L − R) / 2 for absolute frames `frameOffset…+count`, written to
/// the start of `mid` and `side`. A mono input is all Mid (Side = 0); channels past the second
/// are ignored.
void encodeMidSide(const AudioInput& input, float* mid, float* side, std::size_t frameOffset, std::size_t count) noexcept;

/// Rebuilds stereo from Mid and Side for absolute frames `frameOffset…+count`: left = M + S,
/// right = M − S, written to the start of `left` and `right`. Only the first channel of each input
/// is read; an input that is unwired, shorter, or non-finite reads 0.
void decodeMidSide(const AudioInput& mid, const AudioInput& side, float* left, float* right,
                   std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
