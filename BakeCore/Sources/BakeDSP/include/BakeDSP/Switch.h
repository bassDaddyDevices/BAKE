#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// The order a Switch visits its outputs. `BakeGraph`'s `SwitchSteps` mirrors these choices for the card.
enum class SwitchOrder : int { forward = 0, pingPong = 1, random = 2, pattern = 3 };

/// Carried between chunks.
struct SwitchState {
    bool started = false;
    /// True until the first bang (and again after a Reset): that bang plays step 1 instead of moving on,
    /// so a Clock banging on frame 0 doesn't skip Out 1.
    bool armed = true;
    int current = 0;
    int previous = 0;
    double fadeDone = 0;      ///< frames into the crossfade from `previous` to `current`
    int direction = 1;        ///< ping-pong
    int patternIndex = 0;
    std::uint32_t random = 0;
    float previousAdvance = 0;
    float previousReset = 0;
    double fadeLength = 0;    ///< the current move's crossfade, while Crossfade is modulated
};

/// Writes `count` frames of per-output gains, frame-major (`outputs` values per frame). A bang on
/// `advance` (rising above 0.5) moves one step; a bang on `reset` returns to step 1 and wins over
/// an advance on the same frame. Each move crossfades equal-power over `fadeFrames` (0 = instant).
/// `pattern` holds 0-based outputs for `SwitchOrder::pattern`; an empty pattern plays forward.
void renderSwitchGains(SwitchState* state, SwitchOrder order, int outputs, const int* pattern, int patternLength,
                       std::uint32_t seed, double fadeFrames, const ControlInput& advance, const ControlInput& reset,
                       float* gains, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Crossfade (ms) modulatable: `fadeFrames` unless `crossfadeMs` is modulated, then read
/// as each move starts.
void renderSwitchGains(SwitchState* state, SwitchOrder order, int outputs, const int* pattern, int patternLength,
                       std::uint32_t seed, double fadeFrames, const ParameterSignal& crossfadeMs, double sampleRate,
                       const ControlInput& advance, const ControlInput& reset,
                       float* gains, std::size_t frameOffset, std::size_t count) noexcept;

/// `destination[i] = source[i] * gains[i * outputs + output]`: one output's audio for one channel.
void applySwitchGain(const float* gains, int outputs, int output, const float* source, float* destination,
                     std::size_t count) noexcept;

/// The many-in/one-out Switch: `outputs[channel][i] = sum over inputs k of input_k.spread(channel, frameOffset + i) *
/// gains[i * inputCount + k]`, summed in input order. `gains` are `renderSwitchGains` with `outputs == inputCount`.
/// An input shorter than the node reads silence past its end; a mono input feeds every channel.
void mixSwitchInputs(const AudioInput* inputs, std::size_t inputCount, const float* gains, float* const* outputs,
                     std::size_t channels, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
