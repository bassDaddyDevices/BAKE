#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

inline constexpr int maxWavefolderStages = 8;

enum class WavefolderShape : int { triangle = 0, sine = 1 };

/// One point of the folder, for an input `x` in −1…1. Mix is not included. The renderer and the
/// card's transfer-curve plot both mean exactly this.
float wavefolderTransfer(WavefolderShape shape, float x, float fold, float symmetry, int stages, float saturation) noexcept;

/// Fold a signal through repeated reflection, with modulatable amount, symmetry, and Mix.
/// (The original triangle Wavefolder, at the sample rate, with up to `maxWavefolderStages` stages.)
void renderWavefolder(const ParameterSignal& fold, const ParameterSignal& symmetry, const ParameterSignal& mix,
                      int stages, float saturation, const float* input, float* output,
                      std::size_t frameOffset, std::size_t count) noexcept;

/// Scratch floats one `renderWavefolderOversampled` call needs for chunks of up to `maxCount` frames.
std::size_t wavefolderScratchFloats(int oversampling, std::size_t maxCount) noexcept;

/// The Wavefolder with a choice of fold shape and 1–256x oversampling. Folding is brutally aliasing;
/// 32x with a 2049-tap linear-phase filter keeps it clean, which only an offline render can afford.
/// `input` points at frame 0 of the whole channel; frames outside [0, inputFrames) read as silence.
void renderWavefolderOversampled(WavefolderShape shape, int oversampling,
                                 const ParameterSignal& fold, const ParameterSignal& symmetry, const ParameterSignal& mix,
                                 int stages, float saturation,
                                 const float* input, std::size_t inputFrames,
                                 float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept;

/// The same with Saturation and Fold Type modulatable: `saturation` is a signal (its base is the knob),
/// and `shapeIndex` (the WavefolderShape order) picks the shape per sample while it is modulated.
void renderWavefolderOversampled(WavefolderShape shape, const ParameterSignal& shapeIndex, int oversampling,
                                 const ParameterSignal& fold, const ParameterSignal& symmetry, const ParameterSignal& mix,
                                 int stages, const ParameterSignal& saturation,
                                 const float* input, std::size_t inputFrames,
                                 float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept;

} // namespace bake::dsp
