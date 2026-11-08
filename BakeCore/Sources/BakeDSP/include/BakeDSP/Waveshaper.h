#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class WaveshaperCurve : int {
    tanh = 0, arctan, softsign, sine, cubic, hardClip, asymmetric, chebyshev
};

/// One point of the curve, for an input `x` in −1…1: the drive is 1 + 15·`intensity`, `bias`
/// (−1…1) shifts the curve's operating point (the constant it adds at silence is removed), and
/// `intensity` is also how much of the shaped signal replaces the dry one. Mix is not included.
/// The renderer and the card's transfer-curve plot both mean exactly this.
float waveshaperTransfer(WaveshaperCurve curve, float x, float intensity, float bias) noexcept;

/// Stateless, symmetric normalised-tanh waveshaper with an intensity-controlled blend and output Mix.
/// (The original Waveshaper: equals `renderWaveshaperCurve` with tanh, no bias, no oversampling.)
void renderWaveshaper(const ParameterSignal& intensity, const ParameterSignal& mix,
                      const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// Scratch floats one `renderWaveshaperCurve` call needs for chunks of up to `maxCount` frames.
std::size_t waveshaperScratchFloats(int oversampling, std::size_t maxCount) noexcept;

/// The Waveshaper with a choice of curve, bias, and 1–256x oversampling (an offline luxury: the
/// shaper runs on a 2049-tap linear-phase upsampled signal at 32x). `input` points at frame 0 of
/// the whole channel; frames outside [0, inputFrames) read as silence.
/// The same with Curve modulatable (an index in WaveshaperCurve's order), per sample.
void renderWaveshaperCurve(WaveshaperCurve curve, const ParameterSignal& curveIndex, int oversampling,
                           const ParameterSignal& intensity, const ParameterSignal& bias, const ParameterSignal& mix,
                           const float* input, std::size_t inputFrames,
                           float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept;

void renderWaveshaperCurve(WaveshaperCurve curve, int oversampling,
                           const ParameterSignal& intensity, const ParameterSignal& bias, const ParameterSignal& mix,
                           const float* input, std::size_t inputFrames,
                           float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept;

} // namespace bake::dsp
