#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class QuantizerScale : int { chromatic = 0, major, minor, pentatonic };

/// The control signal spans ±24 semitones: ±1 = ±24 st.
inline constexpr float quantizerSemitoneRange = 24.0f;

/// What the quantizer remembers between chunks (only used when it glides).
struct QuantizerState {
    double current = 0.0;
    bool started = false;
};

/// Writes a mono control signal: `input` (clamped to ±1) moved to the nearest note of `scale` built
/// on `root` (0…11 semitones above C; other values wrap), as semitones / 24. Ties go to the lower
/// note. Notes stay within ±24 semitones, so the output is always within ±1. With `glideFrames`
/// above 0 the output slides to each new note with that time constant (a one-pole glide, starting
/// on the first note), so between notes it is not on the scale.
void renderQuantizer(QuantizerState* state, QuantizerScale scale, int root, double glideFrames, const ControlInput& input,
                     float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Glide (seconds) modulatable: `glideFrames` unless `glideSeconds` is modulated.
void renderQuantizer(QuantizerState* state, QuantizerScale scale, int root, double glideFrames, const ParameterSignal& glideSeconds,
                     double sampleRate, const ControlInput& input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with Scale (an index in QuantizerScale's order) and Root (0…11) modulatable, per sample:
/// key changes.
void renderQuantizer(QuantizerState* state, QuantizerScale scale, const ParameterSignal& scaleIndex, int root,
                     const ParameterSignal& rootIndex, double glideFrames, const ParameterSignal& glideSeconds,
                     double sampleRate, const ControlInput& input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
