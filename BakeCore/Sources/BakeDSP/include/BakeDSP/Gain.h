#pragma once

#include <cstddef>

namespace bake::dsp {

/// Multiplies `count` samples in place by `gain`.
/// `samples` is borrowed for the duration of the call only and must not be retained.
void applyGain(float* samples, std::size_t count, float gain) noexcept;

} // namespace bake::dsp
