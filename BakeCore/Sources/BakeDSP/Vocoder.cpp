#include "BakeDSP/Vocoder.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;
constexpr double lowHertz = 80.0;
constexpr double floorLevel = 1e-6;      // in raw FFT magnitude units (full scale reads about 1000)
constexpr double maximumGain = 1000.0;   // +60 dB
constexpr double sibilanceLowHertz = 3500.0;
constexpr double sibilanceHighHertz = 6000.0;
constexpr std::size_t analysisBlock = 32;

std::size_t size(int value) noexcept { return static_cast<std::size_t>(value); }

double warp(VocoderSpacing spacing, double hertz) noexcept {
    switch (spacing) {
    case VocoderSpacing::linear: return hertz;
    case VocoderSpacing::bark: return 13.0 * std::atan(0.00076 * hertz) + 3.5 * std::atan((hertz / 7500.0) * (hertz / 7500.0));
    case VocoderSpacing::mel: return 2595.0 * std::log10(1.0 + hertz / 700.0);
    case VocoderSpacing::logarithmic: break;
    }
    return std::log(std::max(hertz, 1.0));
}

double unwarp(VocoderSpacing spacing, double value) noexcept {
    switch (spacing) {
    case VocoderSpacing::linear: return value;
    case VocoderSpacing::mel: return 700.0 * (std::pow(10.0, value / 2595.0) - 1.0);
    case VocoderSpacing::bark: {
        double low = 0.0, high = 40000.0;
        for (int i = 0; i < 80; ++i) {
            const double middle = 0.5 * (low + high);
            (warp(spacing, middle) < value ? low : high) = middle;
        }
        return 0.5 * (low + high);
    }
    case VocoderSpacing::logarithmic: break;
    }
    return std::exp(value);
}

struct Axis {
    VocoderSpacing spacing;
    int bands;
    double low;    // warped position of the first centre
    double span;   // warped distance from the first to the last centre

    Axis(const VocoderSettings& settings, double sampleRate) noexcept
        : spacing(settings.spacing), bands(vocoderBandCount(settings)),
          low(warp(settings.spacing, vocoderLowHertz())),
          span(warp(settings.spacing, vocoderHighHertz(sampleRate)) - low) {}

    /// Band coordinate of a frequency: 0 at the first centre, bands - 1 at the last, clamped.
    double coordinate(double hertz) const noexcept {
        const double position = span > 0 ? (warp(spacing, hertz) - low) / span * (bands - 1) : 0.0;
        return std::clamp(position, 0.0, static_cast<double>(bands - 1));
    }
};

/// For every bin, the lower of the two bands it feeds and the weight of that band (the upper band
/// gets 1 minus it). `ratio` divides each bin's frequency first, which is how Formant Shift moves
/// the envelope.
void fillTable(const Axis& axis, double sampleRate, int fftSize, double ratio, double* index, double* weight) noexcept {
    const std::size_t bins = size(fftSize) / 2 + 1;
    const double binHertz = sampleRate / fftSize;
    for (std::size_t k = 0; k < bins; ++k) {
        const double position = axis.coordinate(static_cast<double>(k) * binHertz / ratio);
        const double lower = std::min(std::floor(position), static_cast<double>(axis.bands - 2));
        index[k] = lower;
        weight[k] = 1.0 - (position - lower);
    }
}

std::uint32_t hash(std::uint32_t value) noexcept {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    value ^= value >> 16;
    return value;
}

/// Where the scratch is: the STFT's own scratch first, then the vocoder's tables.
struct Scratch {
    double* stft;
    double* window;
    double* analysisIndex;
    double* analysisWeight;
    double* shiftedIndex;
    double* shiftedWeight;
    double* weightSum;   // per band
    double* power;       // per band
    double* gain;        // per band
    double* binGain;     // per bin

    Scratch(const VocoderSettings& settings, double* base) noexcept {
        const StftLayout layout = vocoderLayout();
        const std::size_t bins = stftBinCount(layout);
        const std::size_t bands = size(vocoderBandCount(settings));
        stft = base;
        double* at = base + stftScratchDoubles(layout);
        window = at; at += size(layout.fftSize);
        analysisIndex = at; at += bins;
        analysisWeight = at; at += bins;
        shiftedIndex = at; at += bins;
        shiftedWeight = at; at += bins;
        binGain = at; at += bins;
        weightSum = at; at += bands;
        power = at; at += bands;
        gain = at;
    }
};

void prepareAnalysis(const VocoderSettings& settings, double sampleRate, Scratch& s) noexcept {
    const StftLayout layout = vocoderLayout();
    const Axis axis(settings, sampleRate);
    const std::size_t bins = stftBinCount(layout);
    fillTable(axis, sampleRate, layout.fftSize, 1.0, s.analysisIndex, s.analysisWeight);
    std::fill(s.weightSum, s.weightSum + axis.bands, 0.0);
    for (std::size_t k = 0; k < bins; ++k) {
        const std::size_t lower = static_cast<std::size_t>(s.analysisIndex[k]);
        s.weightSum[lower] += s.analysisWeight[k];
        s.weightSum[lower + 1] += 1.0 - s.analysisWeight[k];
    }
}

/// Band levels (the root mean square of the magnitudes the band weights pick out) of one frame's spectrum.
void bandLevels(const Scratch& s, const float* spectrum, std::size_t bins, int bands, double* levels) noexcept {
    std::fill(levels, levels + bands, 0.0);
    for (std::size_t k = 0; k < bins; ++k) {
        const double power = static_cast<double>(spectrum[2 * k]) * spectrum[2 * k] + static_cast<double>(spectrum[2 * k + 1]) * spectrum[2 * k + 1];
        const std::size_t lower = static_cast<std::size_t>(s.analysisIndex[k]);
        levels[lower] += s.analysisWeight[k] * power;
        levels[lower + 1] += (1.0 - s.analysisWeight[k]) * power;
    }
    for (int b = 0; b < bands; ++b) {
        levels[b] = std::sqrt(levels[b] / std::max(s.weightSum[b], 1e-12));
    }
}

} // namespace

StftLayout vocoderLayout() noexcept { return StftLayout{4096, 1024}; }

int vocoderBandCount(const VocoderSettings& settings) noexcept {
    return std::clamp(settings.bands, minimumVocoderBands, maximumVocoderBands);
}

double vocoderLowHertz() noexcept { return lowHertz; }

double vocoderHighHertz(double sampleRate) noexcept { return std::min(16000.0, 0.45 * sampleRate); }

void vocoderBandCenters(const VocoderSettings& settings, double sampleRate, double* centers) noexcept {
    const Axis axis(settings, sampleRate);
    for (int b = 0; b < axis.bands; ++b) {
        centers[b] = unwarp(axis.spacing, axis.low + axis.span * static_cast<double>(b) / (axis.bands - 1));
    }
}

void vocoderBandMatrix(const VocoderSettings& settings, double sampleRate, float* matrix) noexcept {
    if (matrix == nullptr || !(sampleRate > 0)) {
        return;
    }
    const StftLayout layout = vocoderLayout();
    const Axis axis(settings, sampleRate);
    const std::size_t bins = stftBinCount(layout);
    const double binHertz = sampleRate / layout.fftSize;
    std::fill(matrix, matrix + size(axis.bands) * bins, 0.0f);
    for (std::size_t k = 0; k < bins; ++k) {
        const double position = axis.coordinate(static_cast<double>(k) * binHertz);
        const double lower = std::min(std::floor(position), static_cast<double>(axis.bands - 2));
        matrix[static_cast<std::size_t>(lower) * bins + k] = static_cast<float>(1.0 - (position - lower));
        matrix[(static_cast<std::size_t>(lower) + 1) * bins + k] = static_cast<float>(position - lower);
    }
}

void vocoderMixModulator(const AudioInput& modulator, std::size_t frames, float* mono) noexcept {
    if (mono == nullptr) {
        return;
    }
    const std::size_t channels = modulator.channelCount;
    for (std::size_t frame = 0; frame < frames; ++frame) {
        double sum = 0.0;
        for (std::size_t channel = 0; channel < channels; ++channel) {
            sum += modulator.sample(channel, frame);
        }
        mono[frame] = channels == 0 ? 0.0f : static_cast<float>(sum / static_cast<double>(channels));
    }
}

std::size_t vocoderEnvelopeFloats(const VocoderSettings& settings, std::size_t signalFrames) noexcept {
    return stftFrameCount(vocoderLayout(), signalFrames) * size(vocoderBandCount(settings));
}

std::size_t vocoderScratchDoubles(const VocoderSettings& settings) noexcept {
    const StftLayout layout = vocoderLayout();
    return stftScratchDoubles(layout) + size(layout.fftSize) + 5 * stftBinCount(layout) + 3 * size(vocoderBandCount(settings));
}

std::size_t vocoderWorkFloats(std::size_t maxCount) noexcept {
    const StftLayout layout = vocoderLayout();
    const std::size_t frames = maxCount / size(layout.hop) + stftOverlap(layout) + 2;
    // Per frame: the carrier spectrum, the modulator spectrum, and the time-domain row.
    return frames * (4 * stftBinCount(layout) + size(layout.fftSize));
}

std::size_t vocoderAnalysisWorkFloats() noexcept {
    const StftLayout layout = vocoderLayout();
    return analysisBlock * 2 * stftBinCount(layout);
}

void vocoderAnalyseModulator(const VocoderSettings& settings, double sampleRate, const float* modulator,
                             std::size_t signalFrames, float* envelope, double* scratch, float* work) noexcept {
    vocoderAnalyseModulator(settings, VocoderModulation(), sampleRate, modulator, signalFrames, envelope, scratch, work);
}

void vocoderAnalyseModulator(const VocoderSettings& settings, const VocoderModulation& modulation, double sampleRate,
                             const float* modulator, std::size_t signalFrames, float* envelope, double* scratch, float* work) noexcept {
    if (modulator == nullptr || envelope == nullptr || scratch == nullptr || work == nullptr || !(sampleRate > 0)) {
        return;
    }
    const StftLayout layout = vocoderLayout();
    const std::size_t bins = stftBinCount(layout);
    const int bands = vocoderBandCount(settings);
    const std::size_t frames = stftFrameCount(layout, signalFrames);
    Scratch s(settings, scratch);
    prepareAnalysis(settings, sampleRate, s);

    const double hopSeconds = static_cast<double>(layout.hop) / sampleRate;
    auto coefficient = [&](double milliseconds) { return std::exp(-hopSeconds / std::max(milliseconds / 1000.0, 1e-4)); };
    const double fixedRise = coefficient(settings.attackMilliseconds);
    const double fixedFall = coefficient(settings.releaseMilliseconds);

    double* smoothed = s.gain;
    double* levels = s.power;
    std::fill(smoothed, smoothed + bands, 0.0);
    for (std::size_t first = 0; first < frames; first += analysisBlock) {
        const std::size_t count = std::min(analysisBlock, frames - first);
        stftForward(layout, modulator, signalFrames, first, count, work, s.stft);
        for (std::size_t j = 0; j < count; ++j) {
            bandLevels(s, work + j * 2 * bins, bins, bands, levels);
            float* row = envelope + (first + j) * size(bands);
            const auto centre = static_cast<std::size_t>(std::clamp<long long>(stftFrameCenter(layout, first + j), 0, static_cast<long long>(signalFrames) - 1));
            const double rise = modulation.attack.modulation == nullptr ? fixedRise : coefficient(modulation.attack.valueAt(centre));
            const double fall = modulation.release.modulation == nullptr ? fixedFall : coefficient(modulation.release.valueAt(centre));
            for (int b = 0; b < bands; ++b) {
                const double coef = levels[b] > smoothed[b] ? rise : fall;
                smoothed[b] = coef * smoothed[b] + (1.0 - coef) * levels[b];
                row[b] = static_cast<float>(smoothed[b]);
            }
        }
    }
}

std::size_t vocoderStftFrames(std::size_t signalFrames) noexcept {
    return stftFrameCount(vocoderLayout(), signalFrames);
}

std::size_t vocoderLevelDoubles(const VocoderSettings& settings, std::size_t signalFrames) noexcept {
    return stftFrameCount(vocoderLayout(), signalFrames) * size(vocoderBandCount(settings));
}

void vocoderAnalyseLevels(const VocoderSettings& settings, double sampleRate, const float* modulator,
                          std::size_t signalFrames, std::size_t firstFrame, std::size_t frameCount,
                          double* levels, double* scratch, float* work) noexcept {
    if (modulator == nullptr || levels == nullptr || scratch == nullptr || work == nullptr || !(sampleRate > 0)) {
        return;
    }
    const StftLayout layout = vocoderLayout();
    const std::size_t bins = stftBinCount(layout);
    const int bands = vocoderBandCount(settings);
    Scratch s(settings, scratch);
    prepareAnalysis(settings, sampleRate, s);
    const std::size_t end = firstFrame + frameCount;
    for (std::size_t first = firstFrame; first < end; first += analysisBlock) {
        const std::size_t count = std::min(analysisBlock, end - first);
        stftForward(layout, modulator, signalFrames, first, count, work, s.stft);
        for (std::size_t j = 0; j < count; ++j) {
            bandLevels(s, work + j * 2 * bins, bins, bands, s.power);
            std::copy(s.power, s.power + bands, levels + (first + j) * size(bands));
        }
    }
}

void vocoderSmoothLevels(const VocoderSettings& settings, const VocoderModulation& modulation, double sampleRate,
                         std::size_t signalFrames, const double* levels, float* envelope) noexcept {
    if (levels == nullptr || envelope == nullptr || !(sampleRate > 0)) {
        return;
    }
    const StftLayout layout = vocoderLayout();
    const int bands = vocoderBandCount(settings);
    const std::size_t frames = stftFrameCount(layout, signalFrames);
    const double hopSeconds = static_cast<double>(layout.hop) / sampleRate;
    auto coefficient = [&](double milliseconds) { return std::exp(-hopSeconds / std::max(milliseconds / 1000.0, 1e-4)); };
    const double fixedRise = coefficient(settings.attackMilliseconds);
    const double fixedFall = coefficient(settings.releaseMilliseconds);
    double smoothed[maximumVocoderBands] = {};
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const double* row = levels + frame * size(bands);
        float* out = envelope + frame * size(bands);
        const auto centre = static_cast<std::size_t>(std::clamp<long long>(stftFrameCenter(layout, frame), 0, static_cast<long long>(signalFrames) - 1));
        const double rise = modulation.attack.modulation == nullptr ? fixedRise : coefficient(modulation.attack.valueAt(centre));
        const double fall = modulation.release.modulation == nullptr ? fixedFall : coefficient(modulation.release.valueAt(centre));
        for (int b = 0; b < bands; ++b) {
            const double coef = row[b] > smoothed[b] ? rise : fall;
            smoothed[b] = coef * smoothed[b] + (1.0 - coef) * row[b];
            out[b] = static_cast<float>(smoothed[b]);
        }
    }
}

void vocoderRender(const VocoderSettings& settings, double sampleRate,
                   const ParameterSignal& formantShift, const ParameterSignal& mix,
                   const float* carrier, const float* modulator, std::size_t signalFrames, const float* envelope,
                   float* output, std::size_t frameOffset, std::size_t count,
                   double* scratch, float* work) noexcept {
    vocoderRender(settings, VocoderModulation(), sampleRate, formantShift, mix, carrier, modulator, signalFrames, envelope,
                  output, frameOffset, count, scratch, work);
}

void vocoderRender(const VocoderSettings& settings, const VocoderModulation& modulation, double sampleRate,
                   const ParameterSignal& formantShift, const ParameterSignal& mix,
                   const float* carrier, const float* modulator, std::size_t signalFrames, const float* envelope,
                   float* output, std::size_t frameOffset, std::size_t count,
                   double* scratch, float* work) noexcept {
    if (output == nullptr || count == 0) {
        return;
    }
    if (carrier == nullptr || envelope == nullptr || scratch == nullptr || work == nullptr
        || !(sampleRate > 0) || frameOffset >= signalFrames) {
        std::fill(output, output + count, 0.0f);
        return;
    }
    const std::size_t available = signalFrames - frameOffset;
    if (count > available) {
        std::fill(output + available, output + count, 0.0f);
        count = available;
    }

    const StftLayout layout = vocoderLayout();
    const std::size_t bins = stftBinCount(layout);
    const int bands = vocoderBandCount(settings);
    const double binHertz = sampleRate / layout.fftSize;
    const double fixedSibilance = std::clamp(settings.sibilance, 0.0, 1.0);
    const bool sibilanceMoves = modulation.sibilance.modulation != nullptr;
    const bool addSibilance = (fixedSibilance > 0.0 || sibilanceMoves) && modulator != nullptr;

    const StftFrameRange range = stftFramesCovering(layout, signalFrames, frameOffset, count);
    float* carrierSpectrum = work;
    float* modulatorSpectrum = carrierSpectrum + range.count * 2 * bins;
    float* rows = modulatorSpectrum + range.count * 2 * bins;

    Scratch s(settings, scratch);
    prepareAnalysis(settings, sampleRate, s);
    const Axis axis(settings, sampleRate);

    stftForward(layout, carrier, signalFrames, range.first, range.count, carrierSpectrum, s.stft);
    if (addSibilance) {
        stftForward(layout, modulator, signalFrames, range.first, range.count, modulatorSpectrum, s.stft);
    }

    bool shiftedBuilt = false;
    float builtShift = 0.0f;
    double* carrierLevels = s.power;
    for (std::size_t j = 0; j < range.count; ++j) {
        const std::size_t frame = range.first + j;
        float* spectrum = carrierSpectrum + j * 2 * bins;
        const float* envelopeRow = envelope + frame * size(bands);

        const long long center = std::clamp<long long>(stftFrameCenter(layout, frame), 0, static_cast<long long>(signalFrames) - 1);
        const float shift = formantShift.valueAt(static_cast<std::size_t>(center));
        if (!shiftedBuilt || shift != builtShift) {
            fillTable(axis, sampleRate, layout.fftSize, std::exp2(static_cast<double>(shift) / 12.0), s.shiftedIndex, s.shiftedWeight);
            builtShift = shift;
            shiftedBuilt = true;
        }

        bandLevels(s, spectrum, bins, bands, carrierLevels);
        for (std::size_t k = 0; k < bins; ++k) {
            const std::size_t ai = static_cast<std::size_t>(s.analysisIndex[k]);
            const double aw = s.analysisWeight[k];
            const double own = aw * carrierLevels[ai] + (1.0 - aw) * carrierLevels[ai + 1];
            const std::size_t si = static_cast<std::size_t>(s.shiftedIndex[k]);
            const double sw = s.shiftedWeight[k];
            const double target = sw * envelopeRow[si] + (1.0 - sw) * envelopeRow[si + 1];
            s.binGain[k] = std::min(maximumGain, target / std::max(own, floorLevel));
        }
        for (std::size_t k = 0; k < bins; ++k) {
            spectrum[2 * k] = static_cast<float>(spectrum[2 * k] * s.binGain[k]);
            spectrum[2 * k + 1] = static_cast<float>(spectrum[2 * k + 1] * s.binGain[k]);
        }

        const double sibilance = sibilanceMoves
            ? std::clamp(static_cast<double>(modulation.sibilance.valueAt(static_cast<std::size_t>(center))), 0.0, 1.0) : fixedSibilance;
        if (addSibilance && sibilance > 0.0) {
            const float* source = modulatorSpectrum + j * 2 * bins;
            for (std::size_t k = 1; k < bins; ++k) {
                const double t = std::clamp((static_cast<double>(k) * binHertz - sibilanceLowHertz) / (sibilanceHighHertz - sibilanceLowHertz), 0.0, 1.0);
                if (t <= 0.0) {
                    continue;
                }
                const double ramp = t * t * (3.0 - 2.0 * t);
                const double magnitude = sibilance * ramp * std::hypot(static_cast<double>(source[2 * k]), static_cast<double>(source[2 * k + 1]));
                const double phase = 2.0 * pi * static_cast<double>(hash(static_cast<std::uint32_t>(k) * 7919u + static_cast<std::uint32_t>(frame) * 104729u)) / 4294967296.0;
                spectrum[2 * k] += static_cast<float>(magnitude * std::cos(phase));
                spectrum[2 * k + 1] += k + 1 == bins ? 0.0f : static_cast<float>(magnitude * std::sin(phase));
            }
        }
    }

    stftInverseRows(layout, carrierSpectrum, range.count, rows, s.stft);
    stftWindow(layout, s.window);
    stftOverlapAdd(layout, s.window, rows, range.first, range.count, signalFrames, frameOffset, count, output);

    for (std::size_t i = 0; i < count; ++i) {
        const float wet = std::isfinite(output[i]) ? output[i] : 0.0f;
        const float amount = std::clamp(mix.valueAt(frameOffset + i), 0.0f, 1.0f);
        if (amount >= 1.0f) {
            output[i] = wet;
            continue;
        }
        const float dry = std::isfinite(carrier[frameOffset + i]) ? carrier[frameOffset + i] : 0.0f;
        output[i] = dry + (wet - dry) * amount;
    }
}

} // namespace bake::dsp
