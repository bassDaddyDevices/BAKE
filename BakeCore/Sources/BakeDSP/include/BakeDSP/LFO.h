#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class LFOShape : int { sine = 0, triangle = 1, saw = 2, square = 3, sampleAndHold = 4 };

/// Carried between chunks so splitting a render never changes the waveform.
struct LFOState {
    double phase = 0;          ///< 0..<1; set from the node's phase offset before the first call
    std::uint32_t random = 0;  ///< sample & hold generator state; set from the node's seed
    float held = 0;            ///< current sample & hold value
    bool started = false;
    double resetPhase = 0;     ///< where a bang on Reset restarts the cycle (the node's phase offset)
    float previousReset = 0;   ///< last Reset sample, so a bang across chunks fires once
    // Sync = Clock: the speed follows the gap between bangs on Reset instead of Rate.
    bool clockSync = false;    ///< set by the node's Sync setting
    double cyclesPerBang = 1;  ///< set by the node's Cycles per Bang setting
    long long lastBang = -1;   ///< absolute frame of the last bang; -1 before the first
    double interval = 0;       ///< frames between the last two bangs; 0 (free-running at Rate) until two arrive
    long long bangCount = 0;   ///< bangs so far, to restart only every 2nd or 4th for 1/2 and 1/4
};

/// Writes `count` control samples to `output`. `frameOffset` is the absolute frame of
/// `output[0]`, used to index the rate, depth and reset signals. A bang on `reset` (rising above
/// 0.5) jumps the phase to `resetPhase` and, for sample & hold, takes a new value. Unwired, it
/// does nothing.
/// The same with Phase (degrees) modulatable: a modulated phase reads the shape at the running phase
/// plus (Phase − its knob value) / 360 — phase modulation. Unmodulated, the knob only sets the start.
void renderLFO(LFOState* state, LFOShape shape, const ParameterSignal& rate, const ParameterSignal& depth,
               const ParameterSignal& phaseDegrees, const ControlInput& reset, double sampleRate, float* output,
               std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Shape modulatable too (an index in LFOShape's order), per sample.
void renderLFO(LFOState* state, LFOShape shape, const ParameterSignal& shapeIndex, const ParameterSignal& rate,
               const ParameterSignal& depth, const ParameterSignal& phaseDegrees, const ControlInput& reset,
               double sampleRate, float* output, std::size_t frameOffset, std::size_t count) noexcept;

void renderLFO(LFOState* state, LFOShape shape, const ParameterSignal& rate, const ParameterSignal& depth,
               const ControlInput& reset, double sampleRate, float* output, std::size_t frameOffset,
               std::size_t count) noexcept;

} // namespace bake::dsp
