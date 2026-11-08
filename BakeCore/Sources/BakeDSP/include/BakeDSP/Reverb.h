#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// A feedback delay network: `lines` delay lines mixed by a Householder matrix (orthogonal, so the loop loses energy
/// only where Decay and Damping say), fed through pre-delay and a chain of all-pass diffusers. Each channel has its own
/// network, tuned a little differently, so a stereo input gives a decorrelated stereo reverb.
struct ReverbControls {
    ParameterSignal mix;            ///< 0 = dry, 1 = reverb only
    double width = 1;               ///< 0 mono, 1 as built, up to 2 wider (stereo pairs only)
    double diffusion = 0.7;         ///< 0…1, the all-pass coefficient (× 0.75) of the input diffusers
    double damping = 0.3;           ///< 0…1, how much darker each pass round the loop gets
    double decaySeconds = 3;        ///< RT60: time for the loop to fall 60 dB
    std::size_t lines = 64;
    std::size_t preDelayFrames = 0;
    double sampleRate = 48000;
    /// The wet signal fades out over `[tailFadeStart, tailFadeEnd)` so the tail never ends on a click (0, 0 = none).
    double tailFadeStart = 0;
    double tailFadeEnd = 0;
    /// Early reflections: `reverbEarlyTapCount` taps of the pre-delayed input, spread by `size`, summed to unit energy and
    /// added to the wet signal at this level (0 = off). `earlyFrames` is each channel's buffer for them (`reverbEarlyFrames`).
    double size = 1;
    double earlyLevel = 0;
    std::size_t earlyFrames = 0;
    /// Modulation: each line's read point is swept by a slow LFO of its own, up to ±`modulationDepth` ms (0 = off), which
    /// breaks up the metallic ringing of a fixed network. Every line's ring is `modulationMargin` frames longer than its
    /// length to hold the sweep (`ceil(depth × sampleRate / 1000) + 8`).
    double modulationDepth = 0;
    std::size_t modulationMargin = 0;
    /// Decay per band: below `crossoverHz` the loop decays as if Decay were × `lowDecayScale`, above it × `highDecayScale`
    /// (1, 1 = off). Needs a second damping memory per line (`filters` holds 2 × `lines` doubles per channel).
    double lowDecayScale = 1;
    double highDecayScale = 1;
    double crossoverHz = 800;
    /// From this absolute frame the network takes no more input, its gains go to 1 and Damping is bypassed, so the tail
    /// holds as it is (below 0 = never). The loop closes over `freezeFade` frames.
    double freezeFrame = -1;
    double freezeFade = 0;
};

/// The taps of early reflections per channel.
constexpr std::size_t reverbEarlyTapCount = 12;

/// Frames of buffer the early reflections of a room of `size` need per channel.
std::size_t reverbEarlyFrames(double size, double sampleRate) noexcept;

/// One channel's early-reflection taps: frames behind the pre-delayed input (strictly increasing) and signed gains that
/// fall with time and sum to unit energy.
void reverbEarlyDesign(double size, int channel, double sampleRate, std::size_t* frames, double* gains) noexcept;

/// Delay-line lengths (frames, strictly increasing primes) and the per-pass gain of each line for one channel's
/// network. `size` scales the room: 1 spreads the lines over roughly 20–55 ms.
void reverbDesign(double size, double decaySeconds, std::size_t lines, int channel, double sampleRate,
                  std::uint32_t* lengths, double* gains) noexcept;

/// Floats of storage one channel's network needs: its lines, diffusers and pre-delay.
std::size_t reverbStorageFloats(const std::uint32_t* lengths, std::size_t lines, std::size_t preDelayFrames, double sampleRate) noexcept;

/// Renders `channelCount` coupled channels (1, or 2 when Width isn't 1) for frames `[frameOffset, frameOffset + count)`.
/// Every buffer is indexed by absolute frame, so the only state between chunks is each line's damping memory
/// (`filters`, one double per line). Any chunking gives the same bits.
void renderReverb(const std::uint32_t* const* lengths, const double* const* gains, float* const* storage, double* const* filters,
                  float* const* outputs, int channelCount, int firstChannel, const AudioInput& input,
                  const ReverbControls& controls, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
