#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"
#include "BakeDSP/Oversampling.h"

namespace bake::dsp {

// Adaptive Clipping: a clipper whose ceiling follows the signal's own peak envelope (Threshold dB
// below it, never under Floor), so quiet and loud passages are clipped by the same relative amount.
// Oversampled through `renderOversampledStateful`: the envelope updates once per base frame, in order.

/// The catalog's `knee` options, in order.
enum class AdaptiveClippingKnee : int { hard = 0, soft = 1 };

struct AdaptiveClippingControls {
    ParameterSignal threshold; ///< dB below the envelope, −24…0
    ParameterSignal release;   ///< ms, 5–1000
    ParameterSignal kneeIndex; ///< option index of AdaptiveClippingKnee, when modulated
    ParameterSignal makeup;    ///< dB, 0–24 on the wet signal
    ParameterSignal mix;       ///< 0–1, against the untouched input
    ParameterSignal floor;     ///< dB, −80…−20: the lowest ceiling
    AdaptiveClippingKnee knee = AdaptiveClippingKnee::soft;
    double sampleRate = 48000;
    int oversampling = 8;
    double lookaheadMilliseconds = 0; ///< 0 keeps the causal ceiling; above 0 the ceiling is read ahead (see `buildAdaptiveClippingCeilings`)
};

/// One channel's carried state. Zero-initialise one per channel.
struct AdaptiveClippingState {
    double envelope = 0;
    bool cached = false;
    std::size_t cachedFrame = 0;
    double ceiling = 0; ///< at `cachedFrame`
    AdaptiveClippingKnee knee = AdaptiveClippingKnee::soft;
    OversampledStream stream;
};

std::size_t adaptiveClippingScratchFloats(int oversampling, std::size_t maxCount) noexcept;
std::size_t adaptiveClippingHistoryFloats(int oversampling) noexcept;

/// Renders `count` frames from absolute frame `frameOffset` into `output`. `input` points at frame 0
/// of the whole channel. Ranges must be consecutive across calls, starting at 0.
void renderAdaptiveClipping(AdaptiveClippingState* state, const AdaptiveClippingControls& controls,
                            const float* input, std::size_t inputFrames,
                            float* output, std::size_t frameOffset, std::size_t count,
                            float* scratch, float* history) noexcept;

/// Lookahead: the ceiling at each frame is the highest envelope within the next `lookaheadMilliseconds`, so it has risen
/// before a transient arrives (the release is unchanged). Built for the whole channel first, after which clipping is
/// stateless and any frame range can run on any core.
///
/// Doubles of scratch `buildAdaptiveClippingCeilings` needs for a channel of `frames` frames.
std::size_t adaptiveClippingCeilingScratchDoubles(std::size_t frames) noexcept;

/// Fills `ceilings[0 … frames)` (linear amplitude) for one channel; `input` points at frame 0.
void buildAdaptiveClippingCeilings(const AdaptiveClippingControls& controls, const float* input, std::size_t inputFrames,
                                   std::size_t frames, double* ceilings, double* scratch) noexcept;

/// Clips `count` frames from absolute frame `frameOffset` into `output` against `ceilings`. Stateless: any ranges, any order.
/// `scratch` holds `adaptiveClippingScratchFloats(oversampling, count)` floats.
void renderAdaptiveClippingAhead(const AdaptiveClippingControls& controls, const float* input, std::size_t inputFrames,
                                 const double* ceilings, std::size_t ceilingFrames,
                                 float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept;

} // namespace bake::dsp
