#pragma once

#include <cstddef>

#include "BakeDSP/Filters.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

// Linear-phase FIR filtering for the Filters node: a Kaiser-windowed-sinc kernel (about 100 dB of
// stopband), run by FFT convolution. It is centred on each output frame, so it adds no latency and
// no phase shift at all, which is only possible because the whole file is in memory. Up to 131073
// taps (a 2 Hz edge at 48 kHz) take about a second per ten seconds of audio offline, and are out of
// the question in real time.

inline constexpr int minimumLinearPhaseTaps = 65;
inline constexpr int maximumLinearPhaseTaps = 131073;
inline constexpr double linearPhaseStopbandDecibels = 100.0;

/// The tap count actually used: clamped, and rounded up to an odd number so the kernel has a centre.
int linearPhaseTaps(int requested) noexcept;

/// How wide the edge is, in Hz: from 1 dB down to 90 dB down, measured on the real kernels (the
/// textbook Kaiser estimate, which this is scaled from, runs about 1.47 times wider). The response
/// is 6 dB down (half amplitude) exactly at the cutoff.
double linearPhaseTransitionHz(int taps, double sampleRate) noexcept;

/// Doubles `renderLinearPhaseFilter` needs as scratch. `modulated` is true when Cutoff or Q moves.
std::size_t linearPhaseScratchDoubles(int taps, bool modulated) noexcept;

/// Kaiser window for `linearPhaseTaps(taps)` taps, written to `window`.
void kaiserWindow(int taps, double* window) noexcept;

/// The kernel for one setting, written to `kernel` (`linearPhaseTaps(taps)` doubles). Low-pass has
/// exactly unity gain at DC, high-pass exactly none; Q sets the width of band-pass and notch
/// (the same bandwidth in octaves as a biquad with that Q); Q is ignored by low-pass and high-pass.
void designLinearPhaseKernel(FilterType type, double cutoff, double q, int taps, double sampleRate,
                             const double* window, double* kernel) noexcept;

/// Filters absolute frames `frameOffset…+count` of a whole channel into `output`. `input` points at
/// frame 0; frames outside [0, inputFrames) read as silence. Drive saturates the input as in the
/// biquad filter. Cutoff and Q may move: then the kernel is redesigned every `linearPhaseHop(taps)`
/// frames and neighbouring kernels are cross-faded; otherwise one kernel serves the whole file.
/// Output for a frame depends only on the input within the kernel's reach and the settings at
/// absolute frames, so it is the same however the render is chunked.
void renderLinearPhaseFilter(FilterType type, int taps, const ParameterSignal& cutoff, const ParameterSignal& q,
                             const ParameterSignal& drive, double sampleRate,
                             const float* input, std::size_t inputFrames,
                             float* output, std::size_t frameOffset, std::size_t count, double* scratch) noexcept;

/// The same with Type modulatable: it moves with Cutoff and Q, a kernel per hop window, cross-faded.
void renderLinearPhaseFilter(FilterType type, const ParameterSignal& typeIndex, int taps, const ParameterSignal& cutoff, const ParameterSignal& q,
                             const ParameterSignal& drive, double sampleRate,
                             const float* input, std::size_t inputFrames,
                             float* output, std::size_t frameOffset, std::size_t count, double* scratch) noexcept;

/// Frames between kernel redesigns when Cutoff or Q moves.
std::size_t linearPhaseHop(int taps) noexcept;

} // namespace bake::dsp
