#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class LogicOperator : int { threshold = 0, andGate, orGate, xorGate, notGate };

/// What the gate remembers between chunks.
struct LogicState {
    bool aIsHigh = false;
    bool bIsHigh = false;
    /// Frames the output will stay high after the gate itself has gone low.
    std::size_t holdRemaining = 0;
};

/// Writes a mono gate of exactly 0 or 1 for absolute frames `frameOffset…+count`. An input is
/// high when it is above `threshold` (which can move). With `hysteresis` above 0 it is a Schmitt
/// trigger: it goes high above `threshold + hysteresis` and low below `threshold - hysteresis`, and
/// keeps its state in between, so a noisy signal crossing the threshold does not chatter.
/// `holdFrames` keeps the output high that long after the gate has fallen. Threshold passes `a`;
/// not inverts it; and/or/xor combine `a` and `b`.
void renderLogic(LogicState* state, LogicOperator op, const ControlInput& a, const ControlInput& b,
                 const ParameterSignal& threshold, float hysteresis, std::size_t holdFrames,
                 float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Hysteresis and Hold Time (seconds) modulatable: each is the fixed value above unless
/// its signal is modulated. The hold is read as each gate falls.
void renderLogic(LogicState* state, LogicOperator op, const ControlInput& a, const ControlInput& b,
                 const ParameterSignal& threshold, float hysteresis, std::size_t holdFrames,
                 const ParameterSignal& hysteresisSignal, const ParameterSignal& holdSeconds, double sampleRate,
                 float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Operator modulatable too (an index in LogicOperator's order), per sample.
void renderLogic(LogicState* state, LogicOperator op, const ParameterSignal& operatorIndex, const ControlInput& a,
                 const ControlInput& b, const ParameterSignal& threshold, float hysteresis, std::size_t holdFrames,
                 const ParameterSignal& hysteresisSignal, const ParameterSignal& holdSeconds, double sampleRate,
                 float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
