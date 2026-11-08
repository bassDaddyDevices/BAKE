#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class EnvelopeCurve : int { linear = 0, exponential = 1 };
enum class EnvelopeLoop : int { off = 0, attackDecay = 1 };

/// How a wired trigger drives the envelope. Classic is the pre-v4 behaviour, kept for saved documents:
/// a bang restarts the attack from 0 and the gate's end only counts once in sustain. One-shot plays
/// attack → decay → release on every bang whatever the gate. Gate releases the moment the gate ends.
/// One-shot and Gate retrigger from the current level, so a bang never jumps.
enum class EnvelopeTriggerMode : int { classic = 0, oneShot = 1, gate = 2 };

/// ADSR state retained across render chunks. Trigger edges restart the attack stage.
struct EnvelopeState {
    double level = 0;
    double startLevel = 0;
    double phase = 0;
    float previousTrigger = 0;
    int stage = 0;
    bool initialized = false;
    std::int64_t lastBang = -1;   ///< Repeat: the last Every period that fired
    double timerPosition = 0;     ///< Repeat: periods elapsed, while Every is modulated
};

/// Write a mono, unipolar envelope. `trigger` is an optional full-rate control input;
/// when unwired or never raised, the envelope starts at frame zero and runs once.
void renderEnvelope(EnvelopeState* state, EnvelopeCurve curve, EnvelopeLoop loop, EnvelopeTriggerMode mode,
                    const ParameterSignal& attack, const ParameterSignal& decay,
                    const ParameterSignal& sustain, const ParameterSignal& release,
                    const ParameterSignal& timeScale, const ControlInput& trigger,
                    double sampleRate, float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same, and while `trigger` is unwired and `every` is given, the envelope fires every Every ms
/// from frame 0 (as if banged), so it repeats instead of running once.
void renderEnvelope(EnvelopeState* state, EnvelopeCurve curve, EnvelopeLoop loop, EnvelopeTriggerMode mode,
                    const ParameterSignal& attack, const ParameterSignal& decay,
                    const ParameterSignal& sustain, const ParameterSignal& release,
                    const ParameterSignal& timeScale, const ControlInput& trigger, const ParameterSignal* every,
                    double sampleRate, float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
