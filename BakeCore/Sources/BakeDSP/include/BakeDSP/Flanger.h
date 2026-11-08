#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

enum class FlangerPolarity : int { positive = 0, negative = 1 };
enum class FlangerInterpolation : int { linear = 0, cubic = 1 };

struct FlangerState {
    double dampedFeedback = 0;
    double phase = 0;
};

/// Process one audio channel through a fractional modulated delay. `delayLine` is a zeroed,
/// caller-owned circular buffer sized to cover the maximum delay and the interpolation taps.
void renderFlanger(FlangerState* state, const ParameterSignal& delayMs, const ParameterSignal& rateHz,
                   const ParameterSignal& depth, const ParameterSignal& feedback, const ParameterSignal& mix,
                   FlangerPolarity polarity, FlangerInterpolation interpolation, double hfDamping,
                   double sampleRate, float* delayLine, std::size_t delayLineFrames,
                   const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

/// The same with HF Damping modulatable.
void renderFlanger(FlangerState* state, const ParameterSignal& delayMs, const ParameterSignal& rateHz,
                   const ParameterSignal& depth, const ParameterSignal& feedback, const ParameterSignal& mix,
                   FlangerPolarity polarity, FlangerInterpolation interpolation, double hfDamping, const ParameterSignal& hfDampingSignal,
                   double sampleRate, float* delayLine, std::size_t delayLineFrames,
                   const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept;

// MARK: Through-zero

enum class FlangerWetPolarity : int { positive = 0, negative = 1 };

/// The longest the wet head reaches in either direction, and what the feedback history must cover.
inline constexpr double flangerThroughZeroMaxMs = 50.0;

/// Frames of feedback history for a reach of `maxMs` (zeroed, caller-owned).
std::size_t flangerHistoryFrames(double sampleRate, double maxMs) noexcept;

/// Dispersion runs this many first-order all-pass sections at `amount` 1; `amount` 0 runs none.
inline constexpr int flangerMaxDispersionSections = 256;
inline constexpr double flangerDispersionCoefficient = 0.7;
int flangerDispersionSections(double amount) noexcept;

/// The delay of `sections` all-pass sections at DC, in samples. Higher frequencies lag by more, up to
/// (1 + a) / (1 − a) per section at Nyquist, which is what bends the comb into a chirp.
double flangerDispersionDelay(int sections) noexcept;

/// Disperses a whole channel: `sections` first-order all-passes in series. Unity magnitude at every frequency.
void renderFlangerDispersion(const float* input, std::size_t frames, float* output, int sections) noexcept;

struct FlangerThroughZero {
    ParameterSignal delayMs, rateHz, depth, feedback, mix, hfDampingSignal;
    FlangerPolarity feedbackPolarity = FlangerPolarity::positive;
    FlangerWetPolarity wetPolarity = FlangerWetPolarity::positive;
    FlangerInterpolation interpolation = FlangerInterpolation::cubic;
    double hfDamping = 0;
    double sampleRate = 48'000;
    /// Added to the wet read position, in samples: the dispersion's delay at DC, so low frequencies stay lined up.
    double lookaheadSamples = 0;
};

/// Through-zero flanger for one channel. The wet head sits `delay × (1 − 2 × depth × lfo)` samples behind the
/// input, so it passes through zero and reads the input's future (the whole channel is in memory; nothing past
/// either end is silence). `dry` and `wet` point at frame 0 of the whole channel (`wet` is `dry`, or its
/// dispersed copy); `output` points at frame `frameOffset`. The feedback recirculates the wet signal's own past
/// through a tap at the head's distance from zero, so the resonance sweeps symmetrically. Chunks must be
/// consecutive from frame 0; `history` is a zeroed `flangerHistoryFrames` buffer owned by the channel.
void renderFlangerThroughZero(FlangerState* state, const FlangerThroughZero& controls,
                              const float* dry, const float* wet, std::size_t frames,
                              float* history, std::size_t historyFrames,
                              float* output, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
