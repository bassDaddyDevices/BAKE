#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// What a Generator makes. The noise colours are named for their spectral slope: white is flat, pink falls 3 dB per
/// octave, brown 6, blue rises 3, violet 6. `dust` is sparse random-amplitude clicks, `velvet` sparse +1/−1 clicks,
/// `impulse` a steady train starting at frame 0.
enum class GeneratorType : int { white = 0, pink = 1, brown = 2, blue = 3, violet = 4, dust = 5, velvet = 6, impulse = 7, silence = 8 };

/// Fixed for a render.
struct GeneratorSettings {
    GeneratorType type = GeneratorType::white;
    std::uint32_t seed = 0;
};

/// One per output channel, carried between chunks so splitting a render never changes the signal.
struct GeneratorState {
    bool started = false;
    double pink[7] = {};
    double lastPink = 0;
    double lastWhite = 0;
    double brown = 0;
    double phase = 1;   ///< impulse train: starts at 1, so the first impulse is on frame 0
};

/// Writes `count` samples of channel `channel` to `output`; `frameOffset` is the absolute frame of `output[0]`.
/// `levelDb` is the RMS level for the noise colours and the peak level for dust, velvet and impulse. `density` is
/// events per second for dust, velvet and impulse. Each channel is its own stream (same seed, different channel =
/// uncorrelated noise); impulses are identical on every channel. Noise is drawn from a counter-based hash of
/// (seed, channel, frame), so it never depends on chunking or core count.
void renderGenerator(GeneratorState* state, const GeneratorSettings& settings, int channel, const ParameterSignal& levelDb,
                     const ParameterSignal& density, double sampleRate, float* output, std::size_t frameOffset,
                     std::size_t count) noexcept;

} // namespace bake::dsp
