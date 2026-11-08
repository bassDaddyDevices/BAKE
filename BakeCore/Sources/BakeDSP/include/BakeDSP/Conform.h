#pragma once

#include <cstddef>

namespace bake::dsp {

/// Batch Conform: a mono clip's tempo in BPM (60–200 before folding), or NaN when it has no clear beat (a
/// one-shot, a pad). From an onset envelope (spectral flux, hop 512) whose autocorrelation is scored over
/// fractional lags, with the first four multiples of each period. The result is folded by ×2 or ÷2 to the
/// tempo nearest `target`. Allocates once per call.
double conformTempo(const float* mono, std::size_t frames, double sampleRate, double target) noexcept;

/// The clip's key: 0–11 major on that root (0 = C), 12–23 minor on root (index − 12), or −1 when it has no
/// clear key. A chromagram (4096-point STFT frames inside the clip, 55 Hz–5 kHz) correlated with the
/// Krumhansl–Kessler profiles; the best of 24 keys if its correlation is at least 0.6.
int conformKey(const float* mono, std::size_t frames, double sampleRate) noexcept;

} // namespace bake::dsp
