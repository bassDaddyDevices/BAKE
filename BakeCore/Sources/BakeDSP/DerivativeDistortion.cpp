#include "BakeDSP/DerivativeDistortion.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr double referenceHz = 20000; // 0 dB: limiting starts at a full-scale 20 kHz sine
constexpr double edgeHz = 5000;
constexpr double dcHz = 5;            // removes only the slight offset asymmetric limits leave
constexpr double twoPi = 6.283185307179586;

int factorOf(int oversampling) noexcept { return clampOversampling(std::max(oversampling, 1)); }

/// Coefficients for `frame` at the oversampled rate; recomputed only when the frame changes, so the
/// sub-samples of one frame share them.
void prepare(DerivativeDistortionState& s, const DerivativeDistortionControls& c, std::size_t frame) noexcept {
    if (s.cached && s.cachedFrame == frame) {
        return;
    }
    const double high = c.sampleRate * factorOf(c.oversampling);
    // 1 / (per-sample slope of a full-scale sine at the onset frequency for `decibels`).
    auto limitScale = [high](double decibels) {
        return high / (twoPi * referenceHz * std::pow(2.0, -decibels / 6));
    };
    const double slopeDecibels = c.slopeDrive.valueAt(frame);
    const double splay = c.splay.valueAt(frame);
    const double k = slopeDecibels > 0 ? limitScale(slopeDecibels) : 0;
    s.rising = k * std::pow(2.0, splay);
    s.falling = k * std::pow(2.0, -splay);
    const double curveDecibels = c.curveDrive.valueAt(frame);
    // Curvature of a sine grows with frequency squared.
    s.curve = curveDecibels > 0 ? limitScale(curveDecibels) * limitScale(curveDecibels) : 0;
    s.edgeLowpass = std::exp(-twoPi * edgeHz / high);
    s.dcPole = std::exp(-twoPi * dcHz / high);
    s.edge = c.edge.valueAt(frame);
    s.gain = std::pow(10.0, c.output.valueAt(frame) / 20);
    s.cached = true;
    s.cachedFrame = frame;
}

/// tanh soft limit at ±1/k with unity small-signal gain; k = 0 is the identity.
inline double soft(double value, double k) noexcept { return k > 0 ? std::tanh(k * value) / k : value; }

/// One sample at the oversampled rate.
float step(DerivativeDistortionState& s, float x) noexcept {
    s.lowpass = s.edgeLowpass * s.lowpass + (1 - s.edgeLowpass) * x;
    const double target = x + s.edge * (x - s.lowpass);
    const double distance = target - s.y;
    double wanted = distance;
    if (s.curve > 0) {
        // Follow the target's own speed, plus whatever closes the remaining gap no faster than the
        // curvature limit can still brake from (u² / 2a = gap, a = 1 / curve). Then change the
        // slope by at most the curvature limit.
        const double speed = target - s.target1;
        const double gap = distance - speed;
        const double brake = std::sqrt(2 * std::abs(gap) / s.curve);
        wanted = speed + std::clamp(gap, -brake, brake);
        wanted = s.slope + soft(wanted - s.slope, s.curve);
    }
    s.target1 = target;
    s.slope = soft(wanted, wanted >= 0 ? s.rising : s.falling);
    s.y += s.slope;
    // Block only the distortion's DC, so the linear path stays exact.
    const double error = s.y - target;
    s.blocked = error - s.error1 + s.dcPole * s.blocked;
    s.error1 = error;
    const double out = s.gain * (target + s.blocked);
    if (!std::isfinite(out)) {
        s.y = s.slope = s.lowpass = s.target1 = s.error1 = s.blocked = 0;
        return 0;
    }
    return static_cast<float>(out);
}

} // namespace

std::size_t derivativeDistortionScratchFloats(int oversampling, std::size_t maxCount) noexcept {
    const int factor = factorOf(oversampling);
    return factor < 2 ? 0 : oversamplingScratchFloats(factor, maxCount);
}

std::size_t derivativeDistortionHistoryFloats(int oversampling) noexcept {
    const int factor = factorOf(oversampling);
    return factor < 2 ? 0 : oversampledHistoryFloats(factor);
}

void renderDerivativeDistortion(DerivativeDistortionState* state, const DerivativeDistortionControls& controls,
                                const float* input, std::size_t inputFrames,
                                float* output, std::size_t frameOffset, std::size_t count,
                                float* scratch, float* history) noexcept {
    if (state == nullptr || input == nullptr || output == nullptr || count == 0) {
        return;
    }
    renderOversampledStateful(factorOf(controls.oversampling), input, inputFrames, output, frameOffset, count,
                              scratch, history, state->stream, *state,
                              [&controls](float x, std::size_t frame, DerivativeDistortionState& s) {
                                  prepare(s, controls, frame);
                                  return step(s, x);
                              });
    // Mix at the base rate against the untouched input, so Mix 0 is exact.
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float mix = controls.mix.valueAt(frame);
        const float dry = frame < inputFrames ? input[frame] : 0.0f;
        const float value = mix * output[i] + (1 - mix) * dry;
        output[i] = std::isfinite(value) ? value : 0.0f;
    }
}

} // namespace bake::dsp
