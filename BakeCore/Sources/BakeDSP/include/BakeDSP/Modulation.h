#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace bake::dsp {

/// How a modulation signal moves a parameter.
enum class ModulationScale : int {
    linear = 0,      ///< base + trim·mod·(max − min)
    exponential = 1, ///< base · (max/min)^(trim·mod) — octaves, for frequencies
};

/// A parameter's value over time: its knob value plus an optional modulation signal scaled by
/// the Page 2 trim. `modulation` is borrowed from the render's buffer pool and never owned.
struct ParameterSignal {
    float base = 0;
    float minimum = 0;
    float maximum = 1;
    float trim = 1;
    ModulationScale scale = ModulationScale::linear;
    const float* modulation = nullptr;
    std::size_t modulationFrames = 0;

    /// Effective value at an absolute frame. Past the end of the modulation, its last value holds.
    float valueAt(std::size_t frame) const noexcept {
        if (modulation == nullptr || modulationFrames == 0) {
            return base;
        }
        const float amount = trim * modulation[frame < modulationFrames ? frame : modulationFrames - 1];
        const float value = scale == ModulationScale::exponential
            ? base * std::pow(maximum / minimum, amount)
            : base + amount * (maximum - minimum);
        return std::clamp(value, minimum, maximum);
    }
};

/// `exact` unless `signal` is modulated, then the signal's value at `frame` in its own units, passed
/// through `convert` (e.g. seconds to frames). Kernels that used to take a fixed value read it this
/// way, so an unmodulated render keeps the fixed value's exact bits (a signal's base is a float).
template <typename Convert>
inline double modulatedOr(const ParameterSignal& signal, std::size_t frame, double exact, Convert convert) noexcept {
    return signal.modulation == nullptr ? exact : convert(static_cast<double>(signal.valueAt(frame)));
}

inline double modulatedOr(const ParameterSignal& signal, std::size_t frame, double exact) noexcept {
    return modulatedOr(signal, frame, exact, [](double value) { return value; });
}

/// A choice the user can modulate: `fixed` unless `index` is modulated, then the option nearest the
/// signal's value (0…count − 1, in the catalog's order, which each enum follows).
template <typename Choice>
inline Choice choiceAt(const ParameterSignal& index, std::size_t frame, Choice fixed, int count) noexcept {
    if (index.modulation == nullptr) {
        return fixed;
    }
    const long value = std::lround(static_cast<double>(index.valueAt(frame)));
    return static_cast<Choice>(std::clamp(static_cast<int>(value), 0, count - 1));
}

/// A node's control input pin (e.g. Gain/VCA `amount`, Math `a`/`b`). The source may be shorter
/// than the node — audio may drive a control input — so read it only through `valueAt`.
/// `samples` is borrowed from the render's buffer pool and never owned.
struct ControlInput {
    const float* samples = nullptr;
    std::size_t frames = 0;
    /// Value while nothing is wired.
    float unwired = 0;

    bool isWired() const noexcept { return samples != nullptr && frames > 0; }

    /// Value at an absolute frame. Past the end of the source, its last value holds; non-finite
    /// samples read as 0.
    float valueAt(std::size_t frame) const noexcept {
        if (!isWired()) {
            return unwired;
        }
        const float value = samples[frame < frames ? frame : frames - 1];
        return std::isfinite(value) ? value : 0.0f;
    }
};

} // namespace bake::dsp
