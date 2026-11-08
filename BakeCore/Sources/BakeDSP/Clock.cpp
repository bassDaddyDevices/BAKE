#include "BakeDSP/Clock.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

void renderClock(double framesPerDivision, double gateLength, float* output, std::size_t frameOffset,
                 std::size_t count) noexcept {
    if (output == nullptr) {
        return;
    }
    const double division = std::max(framesPerDivision, 1.0);
    const double high = std::clamp(gateLength, 0.0, 1.0) * division;
    for (std::size_t i = 0; i < count; ++i) {
        const double frame = static_cast<double>(frameOffset + i);
        // Onset k is ceil(k × division), the first whole frame of division k. For a whole frame,
        // ceil(k × division) <= frame exactly when k <= frame / division, so k = floor(frame / division);
        // the check below only corrects a quotient that rounded up to the next whole number.
        double index = std::floor(frame / division);
        double onset = std::ceil(index * division);
        if (onset > frame) {
            index -= 1;
            onset = std::ceil(index * division);
        }
        output[i] = frame - onset < high ? 1.0f : 0.0f;
    }
}

void renderClockModulated(ClockState* state, const ClockControls& controls, float* output, std::size_t frameOffset,
                          std::size_t count) noexcept {
    if (state == nullptr || output == nullptr || controls.quarterNotes == nullptr || controls.divisionCount < 1) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const int index = std::clamp(static_cast<int>(std::lround(controls.division.valueAt(frame))), 0, controls.divisionCount - 1);
        const double bpm = std::clamp(static_cast<double>(controls.bpm.valueAt(frame)), 1.0, 1000.0);
        const double framesPerDivision = std::max(controls.quarterNotes[index] * 60 / bpm * controls.sampleRate, 1.0);
        const double gate = std::clamp(static_cast<double>(controls.gateLength.valueAt(frame)) / 100, 0.0, 1.0);
        output[i] = state->position - std::floor(state->position) < gate ? 1.0f : 0.0f;
        state->position += 1 / framesPerDivision;
    }
}

} // namespace bake::dsp
