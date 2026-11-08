#pragma once

#include <cstddef>

namespace bake::dsp {

/// Corpus Scatter: adds one grain into a stereo output. The grain is `clip` (`clipChannels` 1 or 2, each
/// `clipFrames` long) read at `ratio` times its speed (2^(semitones/12); Catmull-Rom between frames), from
/// output frame `start`, scaled by `gain`, with raised-cosine fades of `fadeFrames` (at most half the grain)
/// at both ends. A mono clip is panned with an equal-power law (−3 dB each side at `pan` 0); a stereo clip
/// keeps its channels and `pan` turns one side down (equal power), so it is untouched at 0. The grain is
/// cut at `outputFrames`. Frames written: the grain's length, `(clipFrames − 1) / ratio + 1`.
std::size_t scatterPlace(const float* const* clip, std::size_t clipChannels, std::size_t clipFrames,
                         float* left, float* right, std::size_t outputFrames,
                         std::size_t start, double ratio, double pan, double gain, std::size_t fadeFrames) noexcept;

/// The grain's length in output frames at `ratio`.
std::size_t scatterGrainFrames(std::size_t clipFrames, double ratio) noexcept;

} // namespace bake::dsp
