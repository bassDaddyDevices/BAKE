#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// Single-sideband frequency shifting. The Hilbert transform is a linear-phase FIR, applied by FFT in independent
/// blocks (so any number of cores can share it), centred so the transformed signal lines up with the input. `precision`
/// picks its length: 0 → 4,097 taps, 1 → 32,769, 2 → 262,145. Longer taps reach lower: the response is flat to within
/// a hair from about 12 Hz × (32768 / taps)⁻¹ … Nyquist minus that, and falls to zero at DC and Nyquist.
std::size_t hilbertTapCount(int precision) noexcept;
/// The FFT size one block uses, and the output frames each block produces.
std::size_t hilbertFftSize(int precision) noexcept;
std::size_t hilbertBlockFrames(int precision) noexcept;
/// Doubles a worker needs as scratch (two FFT-size arrays).
std::size_t hilbertScratchDoubles(int precision) noexcept;
/// Doubles the shared tables need: twiddles (cosines then sines, FFT size / 2 each) and the kernel spectrum (real then
/// imaginary, FFT size each). Fill with `hilbertDesign`.
std::size_t hilbertTableDoubles(int precision) noexcept;
void hilbertDesign(int precision, double* tables) noexcept;

/// Hilbert transform of channel `channel` for frames `[firstFrame, firstFrame + count)`, `count` at most
/// `hilbertBlockFrames`. Stateless: the same bits whatever the split.
void hilbertBlock(const AudioInput& input, std::size_t channel, int precision, const double* tables, double* scratch,
                  std::size_t firstFrame, std::size_t count, float* out) noexcept;

/// Phase of the shift at the start of every `checkpointSpacing` frames, in cycles (the running sum of shift / rate).
/// `absolute` accumulates the magnitude of the shift instead (for the Up and Down outputs). Serial.
inline constexpr std::size_t shiftCheckpointSpacing = 1024;
std::size_t shiftCheckpointCount(std::size_t frames) noexcept;
void shiftCheckpoints(const ParameterSignal& shift, bool absolute, double sampleRate, std::size_t frames, double* cycles) noexcept;

/// Frames `[frameOffset, frameOffset + count)` of one channel. `hilbert` is that channel's whole transformed signal.
/// `sign` +1 shifts by the (signed) shift (or its magnitude with `absolute` checkpoints), -1 the other way.
/// out = x cos φ − H sin φ for φ = sign × phase, then (with `applyMix`) crossfaded with the dry input by `mix`.
/// Stateless given the checkpoints.
void shiftRender(const AudioInput& input, std::size_t channel, const float* hilbert, const ParameterSignal& shift,
                 bool absolute, double sign, double sampleRate, const double* checkpoints, std::size_t frameOffset,
                 std::size_t count, float* out, const ParameterSignal& mix, bool applyMix) noexcept;

} // namespace bake::dsp
