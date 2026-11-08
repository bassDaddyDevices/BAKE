#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"

namespace bake::dsp {

/// Concatenate: frames `first … first + frameCount` of `count` inputs end to end. Input `k` starts at output
/// frame `starts[k]`; its last `holds[k]` frames overlap the next input's first ones with an equal-power
/// crossfade (`a·cos θ + b·sin θ`, `θ = π/2 · (i + ½) / L`), as the batch join does. A mono input feeds every
/// channel; an input with fewer channels leaves the rest silent. `outputs` are `channels` pointers, each
/// already at `first`.
void joinRender(const AudioInput* inputs, std::size_t count, const std::size_t* starts, const std::size_t* holds,
                float* const* outputs, std::size_t channels, std::size_t first, std::size_t frameCount) noexcept;

} // namespace bake::dsp
