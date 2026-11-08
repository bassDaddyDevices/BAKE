#include "BakeDSP/Macro.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

void renderMacro(const ParameterSignal& value, MacroCurve fixedCurve, const ParameterSignal& curveIndex,
                 const ParameterSignal& depth, const ParameterSignal& minimum, const ParameterSignal& maximum,
                 float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (output == nullptr) {
        return;
    }
    constexpr float k = 4.0f;
    const float exponentialDenominator = std::expm1(k);
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const float raw = value.valueAt(frame);
        const float v = std::isfinite(raw) ? std::clamp(raw, 0.0f, 1.0f) : 0.0f;
        const MacroCurve curve = choiceAt(curveIndex, frame, fixedCurve, 3);
        float shaped = v;
        switch (curve) {
        case MacroCurve::linear:
            break;
        case MacroCurve::exponential:
            shaped = std::expm1(k * v) / exponentialDenominator;
            break;
        case MacroCurve::logarithmic:
            shaped = std::log1p(exponentialDenominator * v) / k;
            break;
        }
        const float low = minimum.valueAt(frame);
        const float high = maximum.valueAt(frame);
        const float amount = depth.valueAt(frame) * (low + (high - low) * shaped);
        output[i] = std::isfinite(amount) ? std::clamp(amount, -1.0f, 1.0f) : 0.0f;
    }
}

} // namespace bake::dsp
