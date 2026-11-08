#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"

namespace bake::dsp {

/// What the follower measures. Frequencies are in Hz, `loudness` is momentary (400 ms, K-weighted) LUFS, `crest` is dB,
/// `zeroCrossing` is crossings per sample (0…1), `flatness` is 0…1, `flux` is the summed log-magnitude rise per frame.
enum class Feature : int { centroid = 0, flatness, flux, rolloff, bandwidth, zeroCrossing, crest, loudness };

struct FeatureSettings {
    Feature feature = Feature::centroid;
    double lowCut = 20;        ///< Hz, the band the spectral features look at
    double highCut = 20000;
    double sampleRate = 48000;
};

/// How a feature series becomes a control: `autoRange` maps the file's own 1st…99th percentile to 0…1, otherwise
/// `minimum…maximum` (in the feature's own units) does. Smooth is a zero-phase (forward then backward) one-pole.
struct FeatureShape {
    bool autoRange = true;
    double minimum = 0;
    double maximum = 1;
    double smoothMilliseconds = 50;
    double sampleRate = 48000;
};

/// STFT frame size and hop (a quarter of it); frame `n` is centred on frame `hop × n` of the input.
std::size_t featureFrameSize(double sampleRate) noexcept;
std::size_t featureHop(double sampleRate) noexcept;
std::size_t featureHopCount(std::size_t frames, double sampleRate) noexcept;
std::size_t featureScratchDoubles(double sampleRate) noexcept;

/// Fills `values[firstHop ..< firstHop + count]` with the raw feature of each frame, NaN where it isn't defined
/// (silence). Frames are independent, so ranges may be computed on separate threads with their own `scratch`.
/// Not for `Feature::loudness`; use `featureLoudness`.
void featureFrames(const AudioInput& input, const FeatureSettings& settings, std::size_t firstHop, std::size_t count,
                   double* scratch, double* values) noexcept;

/// Momentary loudness (LUFS, floored at -70) of every frame, serial over the file.
void featureLoudness(const AudioInput& input, const FeatureSettings& settings, std::size_t hopCount, double* values) noexcept;

/// Fills NaN gaps by holding (the first value back-fills the start), normalizes to 0…1 and smooths, in place.
/// Returns false when the series has no defined value at all (the curve is then all 0).
bool featureShape(double* values, std::size_t hopCount, const FeatureShape& shape) noexcept;

/// Frames `[frameOffset, frameOffset + count)` of the control: the series linearly interpolated between frame
/// centres. Stateless, so any chunking gives the same bits.
void featureRender(const double* values, std::size_t hopCount, std::size_t hop, float* out, std::size_t frameOffset,
                   std::size_t count) noexcept;

} // namespace bake::dsp
