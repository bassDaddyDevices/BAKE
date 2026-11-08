#pragma once

#include <cstddef>
#include <cstdint>

namespace bake::dsp {

/// Large Audio Processor: where a long file is cut. The caller streams the file, mixes it to mono and
/// feeds `sliceEnergy`, so the whole file never has to be in memory.

/// Mean square of each `hop` frames of `mono` into `energy` (a final short hop is averaged over what
/// there is): `(frames + hop − 1) / hop` values.
void sliceEnergy(const float* mono, std::size_t frames, std::size_t hop, double* energy) noexcept;

struct SliceSettings {
    double thresholdDb = -40;  ///< an onset is louder than this (dBFS, one hop)
    double sensitivityDb = 6;  ///< … and this much louder than the 100 ms before it
    std::size_t hop = 256;     ///< frames per energy value
    double sampleRate = 48000;
    bool backTrack = true;     ///< move each onset back to the quietest hop of its attack (up to 50 ms)
};

/// Onset frames, ascending, from the whole file's energy (one value per hop). An onset is a hop where
/// both rules start to hold; one comes at most every 30 ms. Returns the count (at most `capacity`).
std::size_t sliceOnsets(const double* energy, std::size_t hops, const SliceSettings& settings,
                        std::size_t* onsets, std::size_t capacity) noexcept;

/// Slice starts → slices. Each slice runs to the next start (the last to `totalFrames`). A slice shorter
/// than `minFrames` joins the one after it (the last joins the one before); one longer than `maxFrames`
/// is cut into `maxFrames` pieces; then each slice's length is scaled by 1 ± `jitter` (0…1) from a
/// counter hash of (`seed`, slice number), so the same seed gives the same lengths. Writes `starts` and
/// `ends` (end exclusive) and returns the count (at most `capacity`).
std::size_t sliceRanges(const std::size_t* boundaries, std::size_t count, std::size_t totalFrames,
                        std::size_t minFrames, std::size_t maxFrames, double jitter, std::uint32_t seed,
                        std::size_t* starts, std::size_t* ends, std::size_t capacity) noexcept;

/// The zero crossing nearest `frame` within `radius` frames, in `mono` holding frames
/// [`firstFrame`, `firstFrame + count`): the first frame of the new sign (or a frame that is exactly 0).
/// Ties go to the earlier frame; with no crossing in reach, `frame` itself.
std::size_t sliceSnap(const float* mono, std::size_t firstFrame, std::size_t count, std::size_t frame,
                      std::size_t radius) noexcept;

} // namespace bake::dsp
