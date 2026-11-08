#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class DistortionMode : int { soft = 0, hard = 1 };

/// Scratch floats one `renderDistortion` call needs for chunks of up to `maxCount` frames.
std::size_t distortionScratchFloats(int oversampling, std::size_t maxCount) noexcept;

/// Oversampled waveshaper. Stateless: output frame n depends only on input frames within
/// ±64 of n, read directly from the whole channel, so chunking never changes the result.
/// `input` points at frame 0; frames outside [0, inputFrames) read as silence.
/// The same with Mode modulatable (an index in DistortionMode's order), per sample.
void renderDistortion(DistortionMode mode, const ParameterSignal& modeIndex, int oversampling,
                      const ParameterSignal& drive, const ParameterSignal& ceiling, const ParameterSignal& mix,
                      const float* input, std::size_t inputFrames,
                      float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept;

void renderDistortion(DistortionMode mode, int oversampling,
                      const ParameterSignal& drive, const ParameterSignal& ceiling, const ParameterSignal& mix,
                      const float* input, std::size_t inputFrames,
                      float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept;

} // namespace bake::dsp
