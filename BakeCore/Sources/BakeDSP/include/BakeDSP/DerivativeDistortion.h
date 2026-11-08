#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"
#include "BakeDSP/Oversampling.h"

namespace bake::dsp {

// Derivative Distortion: distorts movement rather than peaks. At the oversampled rate the output
// chases the input in a closed loop. Each step's slope is the distance still to go, soft-limited
// (Slope Drive, with Splay setting the rising and falling limits apart), and the slope may only change
// as fast as the curvature limit allows (Curve Drive), braking in time so it never overshoots. Edge
// tilts the input above 5 kHz first. With the shapers off the output is the input exactly. Because
// every step aims at the input, errors never accumulate (the first, open-loop design integrated
// them into sub-bass). Drives are measured against a sample-rate-independent reference: 0 dB starts
// limiting at a full-scale 20 kHz sine (transparent), and each +6 dB moves that onset down an octave,
// to about 5 Hz at 72 dB.

struct DerivativeDistortionControls {
    ParameterSignal slopeDrive; ///< dB, 0–72; 0 skips the slope limit
    ParameterSignal curveDrive; ///< dB, 0–48; 0 skips the curvature limit
    ParameterSignal edge;       ///< −1…1: removes (−1) or doubles (+1) the input above 5 kHz
    ParameterSignal splay;      ///< −1…1: the rising limit is ×2^−splay, the falling ×2^splay
    ParameterSignal output;     ///< dB, −24…+24 on the wet signal
    ParameterSignal mix;        ///< 0–1, against the untouched input
    double sampleRate = 48000;
    int oversampling = 8;
};

/// One channel's carried state. Zero-initialise one per channel before the first render.
struct DerivativeDistortionState {
    double y = 0;       ///< output, chasing the input
    double slope = 0;   ///< last step taken
    double lowpass = 0; ///< Edge's 5 kHz lowpass of the input
    double target1 = 0; ///< previous tilted input
    double error1 = 0;  ///< previous distortion (output − tilted input)
    double blocked = 0; ///< distortion with its DC removed (5 Hz)
    bool cached = false;
    std::size_t cachedFrame = 0;
    // Coefficients at `cachedFrame`, at the oversampled rate.
    double rising = 0;
    double falling = 0;
    double curve = 0;
    double edgeLowpass = 0;
    double dcPole = 0;
    double edge = 0;
    double gain = 1;
    OversampledStream stream;
};

/// Scratch floats one call needs for chunks of up to `maxCount` frames (0 at factor 1).
std::size_t derivativeDistortionScratchFloats(int oversampling, std::size_t maxCount) noexcept;

/// History floats each channel carries between calls (0 at factor 1).
std::size_t derivativeDistortionHistoryFloats(int oversampling) noexcept;

/// Renders `count` frames from absolute frame `frameOffset` into `output`. `input` points at frame 0
/// of the whole channel (frames outside [0, inputFrames) read as silence). Ranges must be consecutive
/// across calls, starting at 0, with the same `state` and `history`.
void renderDerivativeDistortion(DerivativeDistortionState* state, const DerivativeDistortionControls& controls,
                                const float* input, std::size_t inputFrames,
                                float* output, std::size_t frameOffset, std::size_t count,
                                float* scratch, float* history) noexcept;

} // namespace bake::dsp
