#include "BakeDSP/Quantizer.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr int range = static_cast<int>(quantizerSemitoneRange);

/// Bit n set = the note n semitones above the root is in the scale.
unsigned mask(QuantizerScale scale) noexcept {
    switch (scale) {
    case QuantizerScale::chromatic: return 0b111111111111;
    case QuantizerScale::major: return 0b101010110101;      // 0 2 4 5 7 9 11
    case QuantizerScale::minor: return 0b010110101101;      // 0 2 3 5 7 8 10
    case QuantizerScale::pentatonic: return 0b001010010101; // 0 2 4 7 9
    }
    return 0b111111111111;
}

bool allowed(unsigned notes, int root, int semitone) noexcept {
    return ((notes >> (((semitone - root) % 12 + 12) % 12)) & 1u) != 0;
}

} // namespace

void renderQuantizer(QuantizerState* state, QuantizerScale scale, int root, double glideFrames, const ControlInput& input,
                     float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderQuantizer(state, scale, root, glideFrames, ParameterSignal(), 48000, input, output, frameOffset, count);
}

void renderQuantizer(QuantizerState* state, QuantizerScale scale, int root, double glideFrames, const ParameterSignal& glideSeconds,
                     double sampleRate, const ControlInput& input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderQuantizer(state, scale, ParameterSignal(), root, ParameterSignal(), glideFrames, glideSeconds, sampleRate, input,
                    output, frameOffset, count);
}

void renderQuantizer(QuantizerState* state, QuantizerScale fixedScale, const ParameterSignal& scaleIndex, int fixedRoot,
                     const ParameterSignal& rootIndex, double glideFrames, const ParameterSignal& glideSeconds,
                     double sampleRate, const ControlInput& input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || output == nullptr) {
        return;
    }
    const bool fixedGlides = std::isfinite(glideFrames) && glideFrames > 0.0;
    const double fixedCoefficient = fixedGlides ? 1.0 - std::exp(-1.0 / glideFrames) : 1.0;
    const unsigned fixedNotes = mask(fixedScale);
    const int fixedRootNote = ((fixedRoot % 12) + 12) % 12;
    for (std::size_t i = 0; i < count; ++i) {
        const unsigned notes = scaleIndex.modulation == nullptr ? fixedNotes : mask(choiceAt(scaleIndex, frameOffset + i, fixedScale, 4));
        const int rootNote = rootIndex.modulation == nullptr ? fixedRootNote : choiceAt(rootIndex, frameOffset + i, 0, 12);
        bool glides = fixedGlides;
        double coefficient = fixedCoefficient;
        if (glideSeconds.modulation != nullptr) {
            const double frames = std::max(static_cast<double>(glideSeconds.valueAt(frameOffset + i)), 0.0) * sampleRate;
            glides = frames > 0.0;
            coefficient = glides ? 1.0 - std::exp(-1.0 / frames) : 1.0;
        }
        const float semitones = std::clamp(input.valueAt(frameOffset + i), -1.0f, 1.0f) * quantizerSemitoneRange;
        const int floorNote = static_cast<int>(std::floor(semitones));
        // Nearest note of the scale at or below, and above, the value; either may be out of range.
        int below = floorNote;
        while (below >= -range && !allowed(notes, rootNote, below)) {
            --below;
        }
        int above = floorNote + 1;
        while (above <= range && !allowed(notes, rootNote, above)) {
            ++above;
        }
        const bool belowFits = below >= -range;
        const bool aboveFits = above <= range;
        int chosen = below;
        if (!belowFits || (aboveFits && above - semitones < semitones - below)) {
            chosen = above;
        }
        const double target = static_cast<double>(chosen) / quantizerSemitoneRange;
        if (!glides || !state->started) {
            state->current = target;
            state->started = true;
        } else {
            state->current += (target - state->current) * coefficient;
        }
        output[i] = static_cast<float>(state->current);
    }
}

} // namespace bake::dsp
