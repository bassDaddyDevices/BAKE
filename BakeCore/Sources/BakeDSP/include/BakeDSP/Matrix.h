#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class MatrixAlign : int { start = 0, peak = 1, random = 2 };

/// Combinatorial Matrix: the frame of an input's loudest sample over every channel (the first, if
/// several tie); 0 for an unwired or silent input.
std::size_t matrixPeakFrame(const AudioInput& input) noexcept;

/// How many frames each of `count` layers is moved later. Start: none. Peak: each wired layer's
/// loudest sample lands where the latest one's is, moved at most `range` frames. Random: each wired
/// layer 0…`range` frames, a counter hash of `seed`, `combination` and the layer's index.
void matrixOffsets(const AudioInput* inputs, std::size_t count, MatrixAlign align, std::size_t range,
                   std::uint64_t seed, std::uint64_t combination, std::size_t* offsets) noexcept;

/// The largest |sample| of the layered sum (each input at its level in dB, moved by its offset; a
/// mono input feeds every channel) over `channels` × `frames`.
double matrixPeak(const AudioInput* inputs, const ParameterSignal* levelsDb, const std::size_t* offsets,
                  std::size_t count, std::size_t channels, std::size_t frames) noexcept;

/// Writes frames `first … first + frameCount` of the layered sum times `scale` into `outputs`
/// (`channels` pointers, each already at `first`).
void matrixRender(const AudioInput* inputs, const ParameterSignal* levelsDb, const std::size_t* offsets,
                  std::size_t count, double scale, float* const* outputs, std::size_t channels,
                  std::size_t first, std::size_t frameCount) noexcept;

} // namespace bake::dsp
