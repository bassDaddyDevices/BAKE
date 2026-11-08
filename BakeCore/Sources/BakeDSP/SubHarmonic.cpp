#include "BakeDSP/SubHarmonic.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr std::size_t blockFrames = 32;
constexpr double hysteresis = 1e-4;
constexpr double attackSeconds = 0.005;

/// RBJ lowpass at `hz`, Q 0.7071; keeps the filter's state.
void setLowpass(SubHarmonicBiquad& f, double hz, double sampleRate) noexcept {
    const double w = 6.283185307179586 * std::clamp(hz, 1.0, 0.45 * sampleRate) / sampleRate;
    const double alpha = std::sin(w) / (2 * 0.7071067811865476);
    const double cosw = std::cos(w);
    const double a0 = 1 + alpha;
    f.b0 = (1 - cosw) / 2 / a0;
    f.b1 = (1 - cosw) / a0;
    f.b2 = f.b0;
    f.a1 = -2 * cosw / a0;
    f.a2 = (1 - alpha) / a0;
}

inline double process(SubHarmonicBiquad& f, double x) noexcept {
    const double y = f.b0 * x + f.z1;
    f.z1 = f.b1 * x - f.a1 * y + f.z2;
    f.z2 = f.b2 * x - f.a2 * y;
    return y;
}

/// Runs `count` identical lowpasses at `hz` over `x` in place, forward then backward, coefficients on absolute 32-frame
/// blocks both ways: the response has no phase shift and the magnitude of the cascade is squared.
void zeroPhaseLowpass(const ParameterSignal& hz, double sampleRate, int count, double* x, std::size_t frames) noexcept {
    SubHarmonicBiquad filters[2];
    count = std::clamp(count, 1, 2);
    for (std::size_t n = 0; n < frames; ++n) {
        if (n % blockFrames == 0) {
            for (int k = 0; k < count; ++k) {
                setLowpass(filters[k], hz.valueAt(n), sampleRate);
            }
        }
        double v = x[n];
        for (int k = 0; k < count; ++k) {
            v = process(filters[k], v);
        }
        x[n] = std::isfinite(v) ? v : 0.0;
        if (!std::isfinite(v)) {
            for (int k = 0; k < count; ++k) {
                filters[k].z1 = 0;
                filters[k].z2 = 0;
            }
        }
    }
    for (int k = 0; k < count; ++k) {
        filters[k].z1 = 0;
        filters[k].z2 = 0;
    }
    std::size_t current = frames;
    for (std::size_t n = frames; n-- > 0;) {
        const std::size_t block = n - n % blockFrames;
        if (block != current) {
            current = block;
            for (int k = 0; k < count; ++k) {
                setLowpass(filters[k], hz.valueAt(block), sampleRate);
            }
        }
        double v = x[n];
        for (int k = 0; k < count; ++k) {
            v = process(filters[k], v);
        }
        x[n] = std::isfinite(v) ? v : 0.0;
        if (!std::isfinite(v)) {
            for (int k = 0; k < count; ++k) {
                filters[k].z1 = 0;
                filters[k].z2 = 0;
            }
        }
    }
}

} // namespace

void renderSubHarmonic(SubHarmonicState* state, const SubHarmonicControls& controls, const AudioInput& input,
                       float* sub, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || sub == nullptr) {
        return;
    }
    SubHarmonicState& s = *state;
    const double sampleRate = controls.sampleRate;
    const double attack = std::exp(-1 / (attackSeconds * sampleRate));
    const double channels = static_cast<double>(std::max<std::size_t>(input.channelCount, 1));
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        // Filter coefficients on absolute 32-frame blocks, so chunking never moves them.
        if (frame % blockFrames == 0 || i == 0) {
            const std::size_t blockStart = frame - frame % blockFrames;
            setLowpass(s.trackFilter, controls.track.valueAt(blockStart), sampleRate);
            const double tone = controls.tone.valueAt(blockStart);
            setLowpass(s.toneFilters[0], tone, sampleRate);
            setLowpass(s.toneFilters[1], tone, sampleRate);
        }
        double mono = 0;
        for (std::size_t c = 0; c < input.channelCount; ++c) {
            mono += input.sample(c, frame);
        }
        const double tracked = process(s.trackFilter, mono / channels);

        // Flip-flops with hysteresis: a crossing counts only after dipping below −1e-4.
        if (tracked < -hysteresis) {
            s.armed = true;
        } else if (s.armed && tracked > hysteresis) {
            s.armed = false;
            s.sub1Sign = -s.sub1Sign;
            if (s.sub1Sign > 0) {
                s.sub2Sign = -s.sub2Sign;
            }
        }

        const double level = std::abs(tracked);
        const double releaseMs = controls.release.valueAt(frame);
        const double release = std::exp(-1 / (releaseMs * 0.001 * sampleRate));
        const double coefficient = level > s.envelope ? attack : release;
        s.envelope = coefficient * s.envelope + (1 - coefficient) * level;

        double value = s.envelope * (controls.sub1.valueAt(frame) * s.sub1Sign + controls.sub2.valueAt(frame) * s.sub2Sign);
        value = process(s.toneFilters[1], process(s.toneFilters[0], value));
        if (!std::isfinite(value)) {
            s = SubHarmonicState();
            value = 0;
        }
        sub[i] = static_cast<float>(value);
    }
}

std::size_t subHarmonicWholeFileScratchDoubles(std::size_t frames) noexcept {
    return 3 * frames + 1;
}

void renderSubHarmonicWholeFile(const SubHarmonicControls& controls, const AudioInput& input, std::size_t frames,
                                float* sub, double* scratch) noexcept {
    if (sub == nullptr || scratch == nullptr || frames == 0) {
        return;
    }
    const double sampleRate = controls.sampleRate;
    const double attack = std::exp(-1 / (attackSeconds * sampleRate));
    const double channels = static_cast<double>(std::max<std::size_t>(input.channelCount, 1));
    double* tracked = scratch;
    double* envelope = scratch + frames;
    double* signs = scratch + 2 * frames;

    for (std::size_t n = 0; n < frames; ++n) {
        double mono = 0;
        for (std::size_t c = 0; c < input.channelCount; ++c) {
            mono += input.sample(c, n);
        }
        tracked[n] = mono / channels;
    }
    zeroPhaseLowpass(controls.track, sampleRate, 1, tracked, frames);

    // The flip-flops and the envelope follower are the causal ones, run on the zero-phase signal.
    float sub1Sign = -1, sub2Sign = -1;
    bool armed = false;
    double follower = 0;
    for (std::size_t n = 0; n < frames; ++n) {
        const double t = tracked[n];
        if (t < -hysteresis) {
            armed = true;
        } else if (armed && t > hysteresis) {
            armed = false;
            sub1Sign = -sub1Sign;
            if (sub1Sign > 0) {
                sub2Sign = -sub2Sign;
            }
        }
        const double level = std::abs(t);
        const double releaseMs = controls.release.valueAt(n);
        const double release = std::exp(-1 / (releaseMs * 0.001 * sampleRate));
        const double coefficient = level > follower ? attack : release;
        follower = coefficient * follower + (1 - coefficient) * level;
        envelope[n] = follower;
        signs[n] = (sub1Sign > 0 ? 1.0 : 0.0) + (sub2Sign > 0 ? 2.0 : 0.0);
    }

    // Read the envelope one attack time ahead, so it has risen by the time the onset arrives.
    const std::size_t lookahead = static_cast<std::size_t>(std::lround(attackSeconds * sampleRate));
    for (std::size_t n = 0; n < frames; ++n) {
        const double code = signs[n];
        const double s1 = (static_cast<int>(code) & 1) ? 1.0 : -1.0;
        const double s2 = (static_cast<int>(code) & 2) ? 1.0 : -1.0;
        const double env = envelope[std::min(n + lookahead, frames - 1)];
        tracked[n] = env * (controls.sub1.valueAt(n) * s1 + controls.sub2.valueAt(n) * s2);
    }
    zeroPhaseLowpass(controls.tone, sampleRate, 2, tracked, frames);
    for (std::size_t n = 0; n < frames; ++n) {
        sub[n] = static_cast<float>(tracked[n]);
    }
}

void addSubHarmonic(const SubHarmonicControls& controls, const float* input, std::size_t inputFrames,
                    const float* sub, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (input == nullptr || sub == nullptr || output == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float dry = frame < inputFrames ? input[frame] : 0.0f;
        const float value = controls.dry.valueAt(frame) * dry + sub[i];
        output[i] = std::isfinite(value) ? value : 0.0f;
    }
}

} // namespace bake::dsp
