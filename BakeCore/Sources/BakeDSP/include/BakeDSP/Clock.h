#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// Writes `count` samples of a Clock: 1 for the first `gateLength` (0…1) of every division,
/// otherwise 0. `framesPerDivision` may be fractional; the first bang starts at frame 0.
/// Each sample depends only on its absolute frame, so chunking never changes the output and
/// long renders never drift.
void renderClock(double framesPerDivision, double gateLength, float* output, std::size_t frameOffset,
                 std::size_t count) noexcept;

/// A Clock whose BPM, Division (an index into `quarterNotes`) or Gate Length (%) is modulated: it keeps a
/// running position in divisions, so the tempo can ramp. Each division's gate is high for its first
/// Gate Length share.
struct ClockControls {
    ParameterSignal bpm;
    ParameterSignal division;
    ParameterSignal gateLength;
    const double* quarterNotes = nullptr;
    int divisionCount = 0;
    double sampleRate = 48000;
};

struct ClockState {
    double position = 0;   ///< divisions elapsed
};

void renderClockModulated(ClockState* state, const ClockControls& controls, float* output, std::size_t frameOffset,
                          std::size_t count) noexcept;

} // namespace bake::dsp
