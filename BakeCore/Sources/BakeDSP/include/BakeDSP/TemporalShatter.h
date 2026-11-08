#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"
#include "BakeDSP/TimeMap.h"

namespace bake::dsp {

// Temporal Shatter & Transient Anchor. The total length is fixed (output = input × Stretch, the
// owner's choice): attacks found on the mono sum keep their first Attack ms at 1×, and the tails share
// the rest of the output, so they stretch by whatever factor fills it. The whole input exists before
// the node runs, so the map is analysed once, up front. Anchors start on whole output frames, so
// every attack is read sample for sample; each tail runs at the speed that lands it exactly on the
// next anchor. Tape mode reads the tails slower (pitch drops); Grains keeps the pitch.

/// The catalog's `mode` options, in order.
enum class TemporalShatterMode : int { grains = 0, tape = 1 };

struct TemporalShatterControls {
    ParameterSignal attack;      ///< ms, 0.5–50: read at each onset's input frame
    ParameterSignal sensitivity; ///< 0–1: read at each hop's input frame
    ParameterSignal grain;       ///< ms, 20–200 (Grains): read at each grain's launch
    TemporalShatterMode mode = TemporalShatterMode::grains;
    double sampleRate = 48000;
};

/// One piece of the map: from output frame `outputStart`, the source runs from `sourceStart` at `speed`.
struct TemporalShatterSegment {
    double outputStart = 0;
    double sourceStart = 0;
    double speed = 1;
    bool anchor = false;
};

/// Most onsets an input of `inputFrames` can have (one per 30 ms, plus one).
std::size_t temporalShatterMaxOnsets(std::size_t inputFrames, double sampleRate) noexcept;
/// Segments the map can need: an anchor and a tail per onset, plus a leading tail.
std::size_t temporalShatterMaxSegments(std::size_t inputFrames, double sampleRate) noexcept;

/// Finds the onsets of `input` (5 ms hops; an onset when a hop's energy rises 12 − 9·Sensitivity dB
/// over the previous one, above −60 dBFS, at least 30 ms after the last) and builds the map onto
/// `outputFrames`. `onsets` holds `temporalShatterMaxOnsets` entries; `segments`
/// `temporalShatterMaxSegments`. Returns the number of segments (at least 1).
std::size_t analyzeTemporalShatter(const TemporalShatterControls& controls, const AudioInput& input,
                                   std::size_t outputFrames, std::size_t* onsets,
                                   TemporalShatterSegment* segments) noexcept;

/// One channel's carried playback state. Zero-initialise one per channel.
struct TemporalShatterState {
    std::size_t segment = 0;
    std::size_t nextLaunch = 0;
    TimeMapGrains grains;
};

/// Renders output frames `frameOffset …` of one channel through the map. `input` is the whole source
/// channel. Chunks must be consecutive, starting at 0.
void renderTemporalShatter(TemporalShatterState* state, const TemporalShatterControls& controls,
                           const TemporalShatterSegment* segments, std::size_t segmentCount,
                           const float* input, std::size_t inputFrames,
                           float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
