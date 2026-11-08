#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class GainMode : int { vca = 0, ringMod = 1 };

/// Apply dB gain and optional amount signal to planar, chunked audio.
void renderGainVCA(GainMode mode, const ParameterSignal& gain, const float* input, const ControlInput& amount,
                   float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
