#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

inline constexpr int maxPhaserStages = 64;

enum class PhaserChannel : int { mono = 0, left = 1, right = 2 };

struct PhaserState {
    double z[maxPhaserStages] = {};
    double previousFeedback = 0;
    double sweepPhase = 0;      ///< 0..<1, carried across chunks
    double dcInput = 0;         ///< DC blocker in the feedback path
    double dcOutput = 0;
};

/// Render a cascaded first-order all-pass phaser. Center and width place the stages;
/// bounded feedback increases resonance and Mix blends the result against the dry signal.
void renderPhaser(PhaserState* state, PhaserChannel channel, int stages,
                  const ParameterSignal& center, const ParameterSignal& width,
                  const ParameterSignal& rate, const ParameterSignal& depth,
                  const ParameterSignal& feedback, const ParameterSignal& mix,
                  double sampleRate, double stereoOffset,
                  const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Stereo Offset (octaves, right channel) modulatable.
void renderPhaser(PhaserState* state, PhaserChannel channel, int stages,
                  const ParameterSignal& center, const ParameterSignal& width,
                  const ParameterSignal& rate, const ParameterSignal& depth,
                  const ParameterSignal& feedback, const ParameterSignal& mix,
                  double sampleRate, double stereoOffset, const ParameterSignal& stereoOffsetSignal,
                  const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

// MARK: Deep phaser (direction, up to 512 stages, retriggered sweep)

inline constexpr int maxPhaserDeepStages = 512;
/// The deep kernel recomputes every stage's coefficient once per block of this many frames.
inline constexpr std::size_t phaserDeepHop = 8;

/// Which way the all-pass chain runs through time. Backward reverses the channel, runs the chain, and reverses
/// back: every transient is smeared before it arrives. Zero phase averages the two, the real part of the
/// chain's response, which has no phase and no time smear.
enum class PhaserDirection : int { forward = 0, backward = 1, zeroPhase = 2 };

struct PhaserDeepState {
    double z[maxPhaserDeepStages] = {};
    double coefficient[maxPhaserDeepStages] = {};
    double previousFeedback = 0;
    double dcInput = 0;
    double dcOutput = 0;
    long long block = -1;
};

/// Frames of onset storage `detectPhaserTransients` can need for a file.
std::size_t phaserTransientCapacity(std::size_t frames, double sampleRate) noexcept;

/// Finds the transients of a whole file (the sum of its channels): where a 1 ms envelope jumps above a 30 ms one.
/// `sensitivity` 0…1; hits are at least 80 ms apart. Writes frame numbers in order, returns how many.
std::size_t detectPhaserTransients(const float* const* channels, std::size_t channelCount, std::size_t frames,
                                   double sampleRate, double sensitivity,
                                   std::int32_t* onsets, std::size_t capacity) noexcept;

/// The sweep's position (0…<1 of a cycle) at every frame of the file. It runs at Rate, restarting from
/// `startPhase` at each onset. Shared by every channel, and by both directions.
void buildPhaserSweep(const ParameterSignal& rate, double sampleRate, std::size_t frames,
                      const std::int32_t* onsets, std::size_t onsetCount, double startPhase, float* sweepPhase) noexcept;

/// Runs the all-pass chain (with feedback) over `count` frames from `first`, forwards or backwards through time,
/// and writes the wet signal for frame f to `output[f − outputBase]`. `input` and `sweepPhase` point at frame 0
/// of the whole channel. Chunks of a forward run must be consecutive from frame 0.
void renderPhaserDeep(PhaserDeepState* state, PhaserChannel channel, int stages,
                      const ParameterSignal& center, const ParameterSignal& width, const ParameterSignal& depth,
                      const ParameterSignal& feedback, double sampleRate, double stereoOffset,
                      const ParameterSignal& stereoOffsetSignal, const float* sweepPhase,
                      const float* input, std::size_t frames,
                      float* output, std::size_t outputBase, std::size_t first, std::size_t count, bool reverse) noexcept;

/// Mixes the wet signal(s) against the dry: forward uses `forwardWet` (indexed from `first`), backward uses
/// `backwardWet` (whole channel), zero phase their average. `output` points at frame `first`.
void renderPhaserDeepBlend(PhaserDirection direction, const ParameterSignal& mix,
                           const float* dry, std::size_t frames,
                           const float* forwardWet, const float* backwardWet,
                           float* output, std::size_t first, std::size_t count) noexcept;

} // namespace bake::dsp
