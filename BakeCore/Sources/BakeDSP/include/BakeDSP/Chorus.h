#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

inline constexpr int maxChorusVoices = 8;

struct ChorusState {
    double phases[maxChorusVoices] = {};
    double writePosition = 0;
};

/// Render a deterministic multi-voice chorus. The preallocated per-channel delay line is
/// owned by the processor and sized for the requested sample rate before rendering begins.
void renderChorus(ChorusState* state, const ParameterSignal& detune, const ParameterSignal& spread,
                  const ParameterSignal& mix, int voices, double driftRate, double panSpread,
                  double sampleRate, double channelPhase,
                  float* delayLine, std::size_t delayLineFrames,
                  const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Drift Rate (Hz) and Pan Spread modulatable: each is the fixed value above unless its
/// signal is modulated.
void renderChorus(ChorusState* state, const ParameterSignal& detune, const ParameterSignal& spread,
                  const ParameterSignal& mix, int voices, double driftRate, double panSpread,
                  const ParameterSignal& driftSignal, const ParameterSignal& panSignal,
                  double sampleRate, double channelPhase,
                  float* delayLine, std::size_t delayLineFrames,
                  const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

// MARK: Swarm

/// The classic kernel handles up to `maxChorusVoices`; more voices, or any Reach, use the swarm.
inline constexpr int maxChorusSwarmVoices = 1024;
inline constexpr double maxChorusReachMs = 5'000.0;

struct ChorusSwarm {
    ParameterSignal detune, spread, mix, driftSignal, panSignal;
    int voices = 16;
    double driftRate = 0.3;
    double panSpread = 0.5;
    double sampleRate = 48'000;
};

/// Doubles `buildChorusSwarmTable` writes: four per voice.
std::size_t chorusSwarmTableDoubles(int voices) noexcept;

/// Per-channel voice table: each voice's resting offset from the fan (samples), its hashed offset within ±Reach for
/// the shared set and for this channel's own set (samples), and its base wobble phase (radians). Deterministic.
void buildChorusSwarmTable(int voices, double reachMs, double sampleRate, std::size_t channel, double* table) noexcept;

/// The wobble's phase at every frame (0…<2π), shared by every voice and channel: what each classic voice
/// accumulates, since they all start together and take the same steps.
void buildChorusDrift(const ParameterSignal& driftSignal, double fixedDriftRate, double sampleRate,
                      std::size_t frames, double* phase) noexcept;

/// Renders frames `frameOffset …` of one channel from the whole input. Every voice reads the input directly, so
/// its delay can be negative (the input's future) and as long as the file. Outside the file is silence. Frame
/// ranges are independent of each other, so they can run on separate threads with identical bits.
void renderChorusSwarm(const ChorusSwarm& controls, bool rightChannel, const double* table, const double* driftPhase,
                       const float* input, std::size_t frames,
                       float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
