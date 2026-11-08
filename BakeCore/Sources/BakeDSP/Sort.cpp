#include "BakeDSP/Sort.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/PitchFollower.h"
#include "BakeDSP/Stft.h"

namespace bake::dsp {

namespace {

constexpr double none = std::numeric_limits<double>::quiet_NaN();

double centroid(const float* mono, std::size_t frames, double sampleRate) {
    // Only frames that lie wholly inside the clip: the silence a frame would read past either end makes
    // the clip's edges a click, which pulls the centroid up. A short clip gets a shorter frame.
    StftLayout layout;
    layout.fftSize = 2048;
    while (layout.fftSize > 64 && static_cast<std::size_t>(layout.fftSize) > frames) layout.fftSize /= 2;
    if (static_cast<std::size_t>(layout.fftSize) > frames) return none;
    layout.hop = layout.fftSize / 4;
    const auto half = static_cast<long long>(layout.fftSize / 2);
    const std::size_t count = stftFrameCount(layout, frames);
    const std::size_t bins = stftBinCount(layout);
    std::vector<float> spectrum(stftSpectrumFloats(layout, 1));
    std::vector<double> scratch(stftScratchDoubles(layout));
    std::vector<double> summed(bins, 0.0);
    for (std::size_t frame = 0; frame < count; ++frame) {
        const long long center = stftFrameCenter(layout, frame);
        if (center < half || center + half > static_cast<long long>(frames)) continue;
        stftForward(layout, mono, frames, frame, 1, spectrum.data(), scratch.data());
        for (std::size_t bin = 0; bin < bins; ++bin) {
            summed[bin] += std::hypot(static_cast<double>(spectrum[2 * bin]), static_cast<double>(spectrum[2 * bin + 1]));
        }
    }
    double weighted = 0.0, total = 0.0;
    for (std::size_t bin = 0; bin < bins; ++bin) {
        weighted += summed[bin] * static_cast<double>(bin) * sampleRate / layout.fftSize;
        total += summed[bin];
    }
    return total > 1e-12 ? weighted / total : none;
}

double loudness(const float* mono, std::size_t frames) {
    double sum = 0.0;
    for (std::size_t i = 0; i < frames; ++i) sum += static_cast<double>(mono[i]) * mono[i];
    const double rms = std::sqrt(sum / static_cast<double>(frames));
    return rms > 1e-10 ? 20.0 * std::log10(rms) : none;
}

double pitch(const float* mono, std::size_t frames, double sampleRate) {
    constexpr double low = 30.0, high = 4'000.0;
    PitchFollowerControls controls;
    controls.minFreq.base = static_cast<float>(low);
    controls.maxFreq.base = static_cast<float>(high);
    controls.glide.base = 0;
    controls.threshold.base = 0.5f;
    controls.output.base = static_cast<float>(PitchFollowerOutput::linear);
    controls.unvoiced.base = static_cast<float>(PitchFollowerUnvoiced::hold);
    controls.fixedOutput = PitchFollowerOutput::linear;
    controls.sampleRate = sampleRate;
    AudioInput input;
    input.channels[0] = mono;
    input.channelCount = 1;
    input.frames = frames;
    const std::size_t estimates = pitchFollowerEstimateCount(frames, sampleRate);
    std::vector<float> table(estimates * pitchFollowerFloatsPerEstimate());
    std::vector<double> scratch(pitchFollowerScratchDoubles(sampleRate));
    pitchFollowerPrepareScratch(sampleRate, scratch.data());
    std::vector<float> track(frames), confidence(frames);
    PitchFollowerState state;
    renderPitchFollower(&state, controls, input, table.data(), estimates, scratch.data(), track.data(), confidence.data(), 0, frames);
    std::vector<double> voiced;
    const std::size_t hop = pitchFollowerHop(sampleRate);
    for (std::size_t i = 0; i < frames; i += hop) {
        if (confidence[i] >= 0.5f) voiced.push_back(low + static_cast<double>(track[i]) * (high - low));
    }
    if (voiced.empty()) return none;
    const auto middle = voiced.begin() + static_cast<std::ptrdiff_t>(voiced.size() / 2);
    std::nth_element(voiced.begin(), middle, voiced.end());
    return *middle;
}

double decay(const float* mono, std::size_t frames, double sampleRate) {
    const auto window = std::max<std::size_t>(1, static_cast<std::size_t>(std::lround(0.005 * sampleRate)));
    std::vector<double> levels;
    for (std::size_t start = 0; start < frames; start += window) {
        const std::size_t end = std::min(frames, start + window);
        double sum = 0.0;
        for (std::size_t i = start; i < end; ++i) sum += static_cast<double>(mono[i]) * mono[i];
        levels.push_back(std::sqrt(sum / static_cast<double>(end - start)));
    }
    const auto loudest = std::max_element(levels.begin(), levels.end());
    if (levels.empty() || *loudest < 1e-10) return none;
    const double floor = *loudest * 0.1;
    std::size_t last = static_cast<std::size_t>(loudest - levels.begin());
    for (std::size_t w = last; w < levels.size(); ++w) {
        if (levels[w] >= floor) last = w;
    }
    const std::size_t peak = static_cast<std::size_t>(loudest - levels.begin());
    return static_cast<double>((last - peak + 1) * window) * 1'000.0 / sampleRate;
}

} // namespace

double sortMeasure(SortMeasure measure, const float* mono, std::size_t frames, double sampleRate) noexcept {
    if (mono == nullptr || frames == 0 || !(sampleRate > 0)) return none;
    try {
        switch (measure) {
        case SortMeasure::centroid: return centroid(mono, frames, sampleRate);
        case SortMeasure::loudness: return loudness(mono, frames);
        case SortMeasure::pitch: return pitch(mono, frames, sampleRate);
        case SortMeasure::decay: return decay(mono, frames, sampleRate);
        }
    } catch (...) {
    }
    return none;
}

} // namespace bake::dsp
