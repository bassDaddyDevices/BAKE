#include "BakeDSP/DualFilter.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr double pi = 3.141592653589793;

/// SplitMix64 of (seed, index), mapped to 0…1.
double unit(std::uint64_t seed, std::uint64_t index) noexcept {
    std::uint64_t z = seed * 0x9E3779B97F4A7C15ull + index;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return static_cast<double>(z >> 11) * (1.0 / 9007199254740992.0);
}

double lfoValue(DualFilterLFOShape shape, double phase, std::uint64_t cycle, std::uint64_t seed) noexcept {
    switch (shape) {
    case DualFilterLFOShape::sine: return std::sin(2 * pi * phase);
    case DualFilterLFOShape::triangle: return phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase;
    case DualFilterLFOShape::saw: return 2 * phase - 1;
    case DualFilterLFOShape::square: return phase < 0.5 ? 1 : -1;
    case DualFilterLFOShape::sampleAndHold: return 2 * unit(seed, cycle) - 1;
    }
    return 0;
}

inline double runSections(DualFilterPath& f, int sections, double x) noexcept {
    const BiquadCoefficients& c = f.coefficients;
    for (int s = 0; s < sections; ++s) {
        const double y = c.b0 * x + f.z1[s];
        f.z1[s] = c.b1 * x - c.a1 * y + f.z2[s];
        f.z2[s] = c.b2 * x - c.a2 * y;
        x = y;
    }
    return x;
}

inline void clearMemory(DualFilterPath& f) noexcept {
    for (int s = 0; s < maxDualFilterSections; ++s) {
        f.z1[s] = 0;
        f.z2[s] = 0;
    }
}

/// Alpha and Beta coefficients at `block`, for an LFO value already read there.
void coefficientsAt(const DualFilterControls& controls, std::size_t block, double lfo, double highest,
                    BiquadCoefficients& alphaOut, BiquadCoefficients& betaOut) noexcept {
    const double rate = controls.sampleRate;
    const bool inverted = choiceAt(controls.lfoPhaseIndex, block, controls.inverted ? 0 : 1, 2) == 0;
    const double depth = 2 * controls.lfoDepth.valueAt(block);
    const double cutoff = controls.cutoff.valueAt(block);
    const double half = controls.bandwidth.valueAt(block) / 2;
    const double q = controls.q.valueAt(block);
    const double alpha = std::clamp(cutoff * std::pow(2.0, half + depth * lfo), 20.0, highest);
    const double beta = std::clamp(cutoff * std::pow(2.0, -half + depth * (inverted ? -lfo : lfo)), 20.0, highest);
    alphaOut = biquadCoefficients(choiceAt(controls.alphaTypeIndex, block, controls.alphaType, 4), alpha, q, rate);
    betaOut = biquadCoefficients(choiceAt(controls.betaTypeIndex, block, controls.betaType, 4), beta, q, rate);
}

inline std::size_t controlInterval(const DualFilterControls& controls) noexcept {
    return controls.perSample ? 1 : filterControlBlock;
}

inline double driveSample(const ParameterSignal& drive, std::size_t frame, double x) noexcept {
    const double driveDb = drive.valueAt(frame);
    if (driveDb > 0) {
        const double g = std::pow(10.0, driveDb / 20);
        return std::tanh(g * x) / g;
    }
    return x;
}

} // namespace

void renderDualFilter(DualFilterState* state, const DualFilterControls& controls,
                      const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderDualFilterDriven(state, controls, input, output, frameOffset, count, nullptr);
}

void renderDualFilterDriven(DualFilterState* state, const DualFilterControls& controls,
                            const float* input, float* output, std::size_t frameOffset, std::size_t count,
                            const float* driven) noexcept {
    if (state == nullptr || input == nullptr || output == nullptr) {
        return;
    }
    DualFilterState& s = *state;
    const double rate = controls.sampleRate;
    const int sections = std::clamp(controls.sections, 1, maxDualFilterSections);
    const double highest = std::min(20000.0, 0.45 * rate);
    const std::size_t interval = controlInterval(controls);
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        if (frame % interval == 0 || !s.alpha.hasCoefficients) {
            const std::size_t block = frame - frame % interval;
            const auto shape = choiceAt(controls.lfoShapeIndex, block, controls.lfoShape, 5);
            const double lfo = lfoValue(shape, s.phase, s.cycle, controls.seed);
            coefficientsAt(controls, block, lfo, highest, s.alpha.coefficients, s.beta.coefficients);
            s.alpha.hasCoefficients = true;
            s.beta.hasCoefficients = true;
        }
        const double x = input[i];
        const double shaped = driven != nullptr ? static_cast<double>(driven[i]) : driveSample(controls.drive, frame, x);
        const double a = runSections(s.alpha, sections, shaped);
        const double b = runSections(s.beta, sections, shaped);
        const double morph = controls.morph.valueAt(frame) * pi / 2;
        const double wet = a * std::cos(morph) + b * std::sin(morph);
        const float mix = controls.mix.valueAt(frame);
        float value = mix * static_cast<float>(wet) + (1 - mix) * input[i];
        if (!std::isfinite(value)) {
            s = DualFilterState();
            value = 0;
        }
        output[i] = value;

        s.phase += controls.lfoRate.valueAt(frame) / rate;
        if (s.phase >= 1) {
            s.phase -= std::floor(s.phase);
            s.cycle += 1;
        }
    }
}

std::size_t dualFilterDriveScratchFloats(int oversampling, std::size_t maxCount) noexcept {
    return oversamplingScratchFloats(oversampling, maxCount);
}

void renderDualFilterDrive(const DualFilterControls& controls, int oversampling,
                           const float* input, std::size_t inputFrames,
                           float* output, std::size_t frameOffset, std::size_t count, float* scratch) noexcept {
    if (input == nullptr || output == nullptr || count == 0) {
        return;
    }
    if (oversampling < 2) {
        for (std::size_t i = 0; i < count; ++i) {
            const std::size_t frame = frameOffset + i;
            output[i] = static_cast<float>(driveSample(controls.drive, frame, input[frame]));
        }
        return;
    }
    const ParameterSignal& drive = controls.drive;
    renderOversampled(oversampling, input, inputFrames, output, frameOffset, count, scratch,
                      [&drive](float upsampled, std::size_t frame) {
                          return static_cast<float>(driveSample(drive, frame, upsampled));
                      });
}

std::size_t dualFilterZeroPhaseScratchDoubles(std::size_t frames, bool perSample) noexcept {
    const std::size_t interval = perSample ? 1 : filterControlBlock;
    return 2 * frames + frames / interval + 2;
}

void renderDualFilterZeroPhase(const DualFilterControls& controls, const float* input, const float* driven,
                               std::size_t frames, float* output, double* scratch) noexcept {
    if (input == nullptr || output == nullptr || scratch == nullptr || frames == 0) {
        return;
    }
    const double rate = controls.sampleRate;
    const int sections = std::clamp(controls.sections, 1, maxDualFilterSections);
    const double highest = std::min(20000.0, 0.45 * rate);
    const std::size_t interval = controlInterval(controls);
    double* alphaOut = scratch;
    double* betaOut = scratch + frames;
    double* lfoStore = scratch + 2 * frames;

    DualFilterState s;
    for (std::size_t i = 0; i < frames; ++i) {
        if (i % interval == 0) {
            const auto shape = choiceAt(controls.lfoShapeIndex, i, controls.lfoShape, 5);
            const double lfo = lfoValue(shape, s.phase, s.cycle, controls.seed);
            lfoStore[i / interval] = lfo;
            coefficientsAt(controls, i, lfo, highest, s.alpha.coefficients, s.beta.coefficients);
        }
        const double shaped = driven != nullptr ? static_cast<double>(driven[i]) : driveSample(controls.drive, i, input[i]);
        double a = runSections(s.alpha, sections, shaped);
        double b = runSections(s.beta, sections, shaped);
        if (!std::isfinite(a) || !std::isfinite(b)) {
            clearMemory(s.alpha);
            clearMemory(s.beta);
            a = 0;
            b = 0;
        }
        alphaOut[i] = a;
        betaOut[i] = b;
        s.phase += controls.lfoRate.valueAt(i) / rate;
        if (s.phase >= 1) {
            s.phase -= std::floor(s.phase);
            s.cycle += 1;
        }
    }

    // Backward: the same filters, run from the end of the file with the coefficients of each frame.
    clearMemory(s.alpha);
    clearMemory(s.beta);
    std::size_t current = frames;
    for (std::size_t n = frames; n-- > 0;) {
        const std::size_t block = n - n % interval;
        if (block != current) {
            current = block;
            coefficientsAt(controls, block, lfoStore[block / interval], highest, s.alpha.coefficients, s.beta.coefficients);
        }
        double a = runSections(s.alpha, sections, alphaOut[n]);
        double b = runSections(s.beta, sections, betaOut[n]);
        if (!std::isfinite(a) || !std::isfinite(b)) {
            clearMemory(s.alpha);
            clearMemory(s.beta);
            a = 0;
            b = 0;
        }
        const double morph = controls.morph.valueAt(n) * pi / 2;
        const double wet = a * std::cos(morph) + b * std::sin(morph);
        const float mix = controls.mix.valueAt(n);
        float value = mix * static_cast<float>(wet) + (1 - mix) * input[n];
        if (!std::isfinite(value)) {
            value = 0;
        }
        output[n] = value;
    }
}

} // namespace bake::dsp
