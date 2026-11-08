#pragma once

#include <cstddef>
#include <cstdint>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// `random`: each step is an independent draw. `walk`: each step moves a bounded random walk (reflected at 0 and 1).
enum class RandomMode : int { random = 0, walk = 1 };

/// How the steps are joined. `stepped` holds each value; the others glide to the next one.
enum class RandomInterpolation : int { stepped = 0, linear = 1, cosine = 2, cubic = 3 };

/// The draw's shape in `random` mode (a walk ignores it).
enum class RandomDistribution : int { uniform = 0, gaussian = 1, coin = 2 };

/// Fixed for a render.
struct RandomSettings {
    RandomMode mode = RandomMode::random;
    RandomInterpolation interpolation = RandomInterpolation::stepped;
    RandomDistribution distribution = RandomDistribution::uniform;
    std::uint32_t seed = 0;
    float stepSize = 0.15f;     ///< walk: the largest move per step, as a fraction of the range
    double glideFrames = 0;     ///< with a trigger wired: how long each move takes (0 = instant)
};

/// Carried between chunks so splitting a render never changes the signal.
struct RandomState {
    bool started = false;
    bool armed = true;               ///< until the first bang, which plays step 0 instead of moving on
    double phase = 0;                ///< 0..<1 through the current step (rate-driven)
    float window[4] = {};            ///< values of steps n-1, n, n+1, n+2, each 0…1
    std::uint64_t generated = 0;     ///< how many step values have been drawn so far
    float walkValue = 0.5f;
    float previousTrigger = 0;
    long long lastBang = -1;         ///< absolute frame of the last bang; -1 before the first
    float from = 0;                  ///< the value the current glide started from (0…1)
    float current = 0;               ///< last value before smoothing (0…1)
    float smoothed = 0;
};

/// Writes `count` control samples to `output`; `frameOffset` is the absolute frame of `output[0]`. Unwired, steps come
/// at `rate` Hz. With a `trigger` wired, each bang (rising above 0.5) takes the next step, and the first bang plays
/// step 0. Values are `min + draw * (max - min)`. `smoothMs` is a one-pole smoother after everything else (0 = off).
/// Step values come from a counter-based hash of (seed, step), so they never depend on chunking or core count.
void renderRandom(RandomState* state, const RandomSettings& settings, const ParameterSignal& rate,
                  const ParameterSignal& minimum, const ParameterSignal& maximum, const ParameterSignal& smoothMs,
                  const ControlInput& trigger, double sampleRate, float* output, std::size_t frameOffset,
                  std::size_t count) noexcept;

} // namespace bake::dsp
