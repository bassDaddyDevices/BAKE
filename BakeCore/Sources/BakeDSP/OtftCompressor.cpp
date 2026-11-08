#include "BakeDSP/OtftCompressor.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

float curveReduction(float x, float slope, float knee) noexcept {
    if (knee > 0.0f && 2.0f * x < -knee) {
        return 0.0f;
    }
    if (knee > 0.0f && 2.0f * std::fabs(x) <= knee) {
        const float shifted = x + knee * 0.5f;
        return slope * shifted * shifted / (2.0f * knee);
    }
    return x > 0.0f ? slope * x : 0.0f;
}

/// The coefficient for "settles in `milliseconds`" along one hop: e^(−hop / time), 0 for no smoothing.
float coefficient(float hopMilliseconds, float milliseconds, float scale) noexcept {
    const float time = milliseconds * scale;
    return time <= 1e-6f ? 0.0f : std::exp(-hopMilliseconds / time);
}

} // namespace

std::size_t otftUnitCount(const StftLayout& layout, std::size_t requested) noexcept {
    const std::size_t bins = stftBinCount(layout);
    if (requested == 0 || requested >= bins) {
        return bins;
    }
    std::vector<std::uint32_t> edges(requested + 1);
    // Reuse the edge builder through a throwaway call.
    otftUnitEdges(layout, requested, edges.data());
    std::size_t count = 0;
    for (std::size_t g = 1; g <= requested; ++g) {
        if (edges[g] > edges[g - 1]) {
            ++count;
        }
    }
    return count;
}

void otftUnitEdges(const StftLayout& layout, std::size_t requested, std::uint32_t* edges) noexcept {
    const std::size_t bins = stftBinCount(layout);
    if (edges == nullptr) {
        return;
    }
    if (requested == 0 || requested >= bins) {
        for (std::size_t k = 0; k <= bins; ++k) {
            edges[k] = static_cast<std::uint32_t>(k);
        }
        return;
    }
    // Log-spaced edges from bin 1 to the last bin; bin 0 (DC) joins the first group. Empty groups collapse.
    const double top = static_cast<double>(bins - 1);
    std::vector<std::uint32_t> raw(requested + 1);
    raw[0] = 0;
    for (std::size_t g = 1; g < requested; ++g) {
        raw[g] = static_cast<std::uint32_t>(std::llround(std::pow(top, static_cast<double>(g) / static_cast<double>(requested))));
    }
    raw[requested] = static_cast<std::uint32_t>(bins);
    std::size_t out = 0;
    edges[out++] = 0;
    for (std::size_t g = 1; g <= requested; ++g) {
        if (raw[g] > edges[out - 1] && (g == requested || raw[g] < bins)) {
            edges[out++] = raw[g];
        }
    }
    // `otftUnitCount` counts the non-empty groups the same way; pad nothing: the caller sized `edges` for `requested + 1`.
    if (edges[out - 1] != bins) {
        edges[out - 1] = static_cast<std::uint32_t>(bins);
    }
    for (std::size_t g = out; g <= requested; ++g) {
        edges[g] = static_cast<std::uint32_t>(bins);
    }
}

void otftUnitTables(const StftLayout& layout, double sampleRate, const std::uint32_t* edges, std::size_t units,
                    double tilt, const OtftCurvePoint* curve, std::size_t curvePoints, float* timeScale,
                    float* offsetDb) noexcept {
    const double binHz = sampleRate / static_cast<double>(layout.fftSize);
    auto curveAt = [&](double hertz) {
        if (curve == nullptr || curvePoints == 0) {
            return 0.0;
        }
        if (hertz <= curve[0].hertz) {
            return static_cast<double>(curve[0].decibels);
        }
        for (std::size_t i = 1; i < curvePoints; ++i) {
            if (hertz <= curve[i].hertz) {
                const double a = std::log(std::max<double>(curve[i - 1].hertz, 1.0)), b = std::log(std::max<double>(curve[i].hertz, 1.0));
                const double t = b > a ? (std::log(hertz) - a) / (b - a) : 0.0;
                return curve[i - 1].decibels + t * (curve[i].decibels - curve[i - 1].decibels);
            }
        }
        return static_cast<double>(curve[curvePoints - 1].decibels);
    };
    const double reference = curveAt(1000.0);
    for (std::size_t u = 0; u < units; ++u) {
        const double centreBin = 0.5 * (static_cast<double>(edges[u]) + static_cast<double>(edges[u + 1]) - 1.0);
        const double hertz = std::max(centreBin * binHz, 20.0);
        if (timeScale != nullptr) {
            timeScale[u] = static_cast<float>(std::clamp(std::pow(hertz / 1000.0, -tilt), 0.05, 20.0));
        }
        if (offsetDb != nullptr) {
            offsetDb[u] = static_cast<float>(curveAt(hertz) - reference);
        }
    }
}

void otftBinMap(const StftLayout& layout, const std::uint32_t* edges, std::size_t units, std::uint32_t* lower,
                float* weight) noexcept {
    const std::size_t bins = stftBinCount(layout);
    std::vector<double> centre(units);
    for (std::size_t u = 0; u < units; ++u) {
        centre[u] = 0.5 * (static_cast<double>(edges[u]) + static_cast<double>(edges[u + 1]) - 1.0);
    }
    std::size_t unit = 0;
    for (std::size_t k = 0; k < bins; ++k) {
        const double position = static_cast<double>(k);
        if (units == 1 || position <= centre[0]) {
            lower[k] = 0;
            weight[k] = 0;
            continue;
        }
        if (position >= centre[units - 1]) {
            lower[k] = static_cast<std::uint32_t>(units - 1);
            weight[k] = 0;
            continue;
        }
        while (unit + 2 < units && centre[unit + 1] <= position) {
            ++unit;
        }
        const double a = std::log(centre[unit] + 1.0), b = std::log(centre[unit + 1] + 1.0);
        lower[k] = static_cast<std::uint32_t>(unit);
        weight[k] = static_cast<float>(std::clamp((std::log(position + 1.0) - a) / (b - a), 0.0, 1.0));
    }
}

void otftFrameParams(const StftLayout& layout, std::size_t signalFrames, std::size_t frameCount,
                     const ParameterSignal& downThreshold, const ParameterSignal& downRatio,
                     const ParameterSignal& upThreshold, const ParameterSignal& upRatio,
                     const ParameterSignal& maxBoost, const ParameterSignal& attack, const ParameterSignal& release,
                     OtftFrameParams* out) noexcept {
    if (out == nullptr || signalFrames == 0) {
        return;
    }
    auto slope = [](double ratio) { return ratio >= 100.0 ? 1.0f : static_cast<float>(1.0 - 1.0 / std::max(ratio, 1.0)); };
    for (std::size_t t = 0; t < frameCount; ++t) {
        const long long centre = std::clamp<long long>(stftFrameCenter(layout, t), 0, static_cast<long long>(signalFrames) - 1);
        const std::size_t at = static_cast<std::size_t>(centre);
        OtftFrameParams frame;
        frame.downThreshold = downThreshold.valueAt(at);
        frame.downSlope = slope(downRatio.valueAt(at));
        frame.upThreshold = upThreshold.valueAt(at);
        frame.upSlope = slope(upRatio.valueAt(at));
        frame.maxBoost = std::max(maxBoost.valueAt(at), 0.0f);
        frame.attackMs = std::max(attack.valueAt(at), 0.0f);
        frame.releaseMs = std::max(release.valueAt(at), 0.0f);
        out[t] = frame;
    }
}

std::size_t otftScratchDoubles(const StftLayout& layout) noexcept {
    return stftScratchDoubles(layout) + 8;
}

void otftLevels(const StftLayout& layout, const float* signal, std::size_t signalFrames, std::size_t firstFrame,
                std::size_t frameCount, const std::uint32_t* edges, std::size_t units, bool combineMax, float* levels,
                float* spectrum, double* scratch) noexcept {
    const std::size_t bins = stftBinCount(layout);
    stftForward(layout, signal, signalFrames, firstFrame, frameCount, spectrum, scratch);
    const float reference = static_cast<float>(layout.fftSize) * 0.25f;   // a full-scale sine's peak bin under a Hann window
    for (std::size_t f = 0; f < frameCount; ++f) {
        const float* row = spectrum + f * bins * 2;
        float* out = levels + (firstFrame + f) * units;
        for (std::size_t u = 0; u < units; ++u) {
            double power = 0;
            for (std::size_t k = edges[u]; k < edges[u + 1]; ++k) {
                const double re = row[2 * k], im = row[2 * k + 1];
                power += re * re + im * im;
            }
            const double magnitude = std::sqrt(power / static_cast<double>(edges[u + 1] - edges[u]));
            const float level = magnitude <= 0 ? otftFloorDb
                : std::max(otftFloorDb, static_cast<float>(20.0 * std::log10(magnitude / reference)));
            out[u] = combineMax ? std::max(out[u], level) : level;
        }
    }
}

float otftGainDb(float levelDb, const OtftFrameParams& frame, float offsetDb, float kneeDb) noexcept {
    const float reduction = curveReduction(levelDb - (frame.downThreshold + offsetDb), frame.downSlope, kneeDb);
    const float boost = std::min(curveReduction((frame.upThreshold + offsetDb) - levelDb, frame.upSlope, kneeDb), frame.maxBoost);
    return boost - reduction;
}

void otftGainColumns(const OtftFrameParams* frames, std::size_t frameCount, std::size_t units, std::size_t firstUnit,
                     std::size_t unitCount, const float* timeScale, const float* offsetDb, const OtftEnvelope& envelope,
                     float* surface, float* column) noexcept {
    if (frames == nullptr || surface == nullptr || frameCount == 0) {
        return;
    }
    for (std::size_t u = firstUnit; u < firstUnit + unitCount; ++u) {
        const float scale = timeScale != nullptr ? timeScale[u] : 1.0f;
        const float offset = offsetDb != nullptr ? offsetDb[u] : 0.0f;
        const float hop = envelope.hopMilliseconds;
        if (envelope.anticipating != 0) {
            // Look-ahead works on the gain, not the level, so the gain ramps in before a loud frame: measured as how far under
            // its most generous value (the Max Boost) each frame wants to be, that distance eases down backwards in time from
            // every deep frame at the attack rate, and forwards the gain recovers at the release rate.
            float carried = 0.0f;
            for (std::size_t t = frameCount; t-- > 0;) {
                const float a = coefficient(hop, frames[t].attackMs, scale);
                const float wanted = frames[t].maxBoost - otftGainDb(surface[t * units + u], frames[t], offset, envelope.kneeDb);
                carried = std::max(wanted, carried * a);
                surface[t * units + u] = carried;
            }
            float held = 0.0f;
            for (std::size_t t = 0; t < frameCount; ++t) {
                const float r = coefficient(hop, frames[t].releaseMs, scale);
                const float target = surface[t * units + u];
                held = target >= held ? target : target + (held - target) * r;
                surface[t * units + u] = frames[t].maxBoost - held;
            }
        } else {
            float state = otftFloorDb;
            for (std::size_t t = 0; t < frameCount; ++t) {
                const float level = surface[t * units + u];
                const float c = coefficient(hop, level > state ? frames[t].attackMs : frames[t].releaseMs, scale);
                state = level + (state - level) * c;
                surface[t * units + u] = otftGainDb(state, frames[t], offset, envelope.kneeDb);
            }
        }
        if (envelope.smoothFrames > 0 && column != nullptr) {
            const long long radius = envelope.smoothFrames;
            const long long n = static_cast<long long>(frameCount);
            for (long long t = 0; t < n; ++t) {
                column[t] = surface[static_cast<std::size_t>(t) * units + u];
            }
            // A running mean over ±radius with the edges held.
            double sum = 0;
            for (long long k = -radius; k <= radius; ++k) {
                sum += column[std::clamp<long long>(k, 0, n - 1)];
            }
            const double width = static_cast<double>(2 * radius + 1);
            for (long long t = 0; t < n; ++t) {
                surface[static_cast<std::size_t>(t) * units + u] = static_cast<float>(sum / width);
                sum += column[std::clamp<long long>(t + radius + 1, 0, n - 1)] - column[std::clamp<long long>(t - radius, 0, n - 1)];
            }
        }
    }
}

std::size_t otftRenderFloats(const StftLayout& layout, std::size_t count) noexcept {
    const std::size_t bins = stftBinCount(layout);
    const std::size_t frames = count / static_cast<std::size_t>(layout.hop) + stftOverlap(layout) + 2;
    // The spectrum, the time rows, and one frame's linear gains.
    return stftSpectrumFloats(layout, frames) + stftRowFloats(layout, frames) + bins;
}

void otftRenderBlock(const StftLayout& layout, const double* window, const float* signal, std::size_t signalFrames,
                     const float* surface, std::size_t units, const std::uint32_t* lower, const float* weight,
                     double smoothFreq, std::size_t sampleStart, std::size_t count, float* output, float* floats,
                     double* scratch) noexcept {
    if (count == 0 || output == nullptr) {
        return;
    }
    const std::size_t bins = stftBinCount(layout);
    const StftFrameRange range = stftFramesCovering(layout, signalFrames, sampleStart, count);
    if (range.count == 0) {
        std::fill(output, output + count, 0.0f);
        return;
    }
    float* spectrum = floats;
    float* rows = spectrum + stftSpectrumFloats(layout, range.count);
    float* gains = rows + stftRowFloats(layout, range.count);
    stftForward(layout, signal, signalFrames, range.first, range.count, spectrum, scratch);
    std::vector<double> prefix(bins + 1);
    std::vector<float> decibels(bins);
    for (std::size_t f = 0; f < range.count; ++f) {
        const float* row = surface + (range.first + f) * units;
        for (std::size_t k = 0; k < bins; ++k) {
            decibels[k] = units == bins ? row[k] : (1.0f - weight[k]) * row[lower[k]] + weight[k] * row[std::min<std::size_t>(lower[k] + 1, units - 1)];
        }
        if (smoothFreq > 0) {
            prefix[0] = 0;
            for (std::size_t k = 0; k < bins; ++k) {
                prefix[k + 1] = prefix[k] + decibels[k];
            }
            for (std::size_t k = 0; k < bins; ++k) {
                const long long radius = static_cast<long long>(std::llround(smoothFreq * 0.1 * static_cast<double>(k)));
                const long long lo = std::max<long long>(static_cast<long long>(k) - radius, 0);
                const long long hi = std::min<long long>(static_cast<long long>(k) + radius, static_cast<long long>(bins) - 1);
                gains[k] = std::pow(10.0f, static_cast<float>((prefix[static_cast<std::size_t>(hi) + 1] - prefix[static_cast<std::size_t>(lo)]) / static_cast<double>(hi - lo + 1)) / 20.0f);
            }
        } else {
            for (std::size_t k = 0; k < bins; ++k) {
                gains[k] = std::pow(10.0f, decibels[k] / 20.0f);
            }
        }
        stftApplyGains(spectrum + f * bins * 2, 1, bins, gains);
    }
    stftInverseRows(layout, spectrum, range.count, rows, scratch);
    stftOverlapAdd(layout, window, rows, range.first, range.count, signalFrames, sampleStart, count, output);
}

void otftMixDown(const ParameterSignal& mix, const ParameterSignal& outputGain, double makeupDb, bool includeOutputGain,
                 const float* dry, const float* wet, std::size_t frameOffset, std::size_t count, float* out) noexcept {
    if (out == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double amount = std::clamp(static_cast<double>(mix.valueAt(frame)), 0.0, 1.0);
        const double decibels = makeupDb + (includeOutputGain ? static_cast<double>(outputGain.valueAt(frame)) : 0.0);
        const double dryValue = dry != nullptr ? static_cast<double>(dry[frame]) : 0.0;
        const double wetValue = wet != nullptr ? static_cast<double>(wet[i]) : 0.0;
        out[i] = static_cast<float>((dryValue + (wetValue - dryValue) * amount) * std::pow(10.0, decibels / 20.0));
    }
}

} // namespace bake::dsp
