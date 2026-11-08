#pragma once

#include <cstddef>

namespace bake::dsp {

enum class SortMeasure : int { centroid = 0, loudness = 1, pitch = 2, decay = 3 };

/// Spectral Sorter: one number for a whole mono clip, or NaN when it has none (digital silence, or no
/// clear pitch).
/// - centroid: Hz, Σ f·|X(f)| / Σ |X(f)| over the summed STFT magnitudes of the frames wholly inside the
///   clip (2048-point Hann, hop 512; shorter for a clip under 2048 frames, none under 64);
/// - loudness: RMS in dBFS;
/// - pitch: Hz, the median of the Pitch Follower's estimates (30 Hz–4 kHz) whose confidence is at least 0.5;
/// - decay: ms from the start of the loudest 5 ms window to the end of the last one within 20 dB of it.
/// Allocates its working buffers once per call.
double sortMeasure(SortMeasure measure, const float* mono, std::size_t frames, double sampleRate) noexcept;

} // namespace bake::dsp
