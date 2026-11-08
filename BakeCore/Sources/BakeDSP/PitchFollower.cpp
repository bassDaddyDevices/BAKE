#include "BakeDSP/PitchFollower.h"

#include <algorithm>
#include <cmath>

#include "BakeDSP/Fft.h"

namespace bake::dsp {
namespace {

// An estimate's floats: its raw pitch (log2 Hz, or `none`), confidence, the median of its voiced
// neighbours (or `none`), and the last voiced median up to it (or `none`); then, for the whole-file
// path, up to `maxCandidates` candidate pitches with each one's local cost, the cheapest route to it
// so far, and where that route came from.
constexpr std::size_t maxCandidates = 4;
constexpr std::size_t candidateSlot = 4;
constexpr std::size_t costSlot = candidateSlot + maxCandidates;
constexpr std::size_t routeSlot = costSlot + maxCandidates;
constexpr std::size_t fromSlot = routeSlot + maxCandidates;
constexpr std::size_t floatsPerEstimate = fromSlot + maxCandidates;
constexpr std::size_t rawSlot = 0, confidenceSlot = 1, medianSlot = 2, heldSlot = 3;
/// "No pitch" in a log2-Hz slot (a sentinel rather than NaN, so comparisons stay simple).
constexpr float none = -1000.0f;
constexpr double hopSeconds = 0.005;
/// YIN's absolute threshold: the first dip below it is the period.
constexpr double dipThreshold = 0.15;
/// The median looks this many estimates either side at the 5 ms hop (10 ms), and as many as span the same time at finer hops.
constexpr std::size_t shortestMedianReach = 2;
constexpr std::size_t longestMedianReach = 40;
/// A candidate must dip below this to count, and be this many octaves from the others.
constexpr double candidateCeiling = 0.6;
constexpr double candidateSeparation = 0.04;
/// The cost of an octave between neighbouring estimates on the whole-file path.
constexpr double octaveCost = 2.0;
constexpr float noRoute = 1.0e9f;
constexpr double log2Of440 = 8.78135971352466;

bool isPitch(float value) noexcept { return value > none + 1.0f; }

std::size_t hopFrames(double sampleRate, double hopSeconds) noexcept {
    if (!(sampleRate > 0.0) || !std::isfinite(sampleRate) || !(hopSeconds > 0.0) || !std::isfinite(hopSeconds)) {
        return 1;
    }
    return std::max<std::size_t>(1, static_cast<std::size_t>(std::lround(sampleRate * hopSeconds)));
}

std::size_t medianReachFor(double hopSeconds) noexcept {
    if (!(hopSeconds > 0.0) || !std::isfinite(hopSeconds)) {
        return shortestMedianReach;
    }
    const long reach = std::lround(0.010 / hopSeconds);
    return static_cast<std::size_t>(std::clamp<long>(reach, static_cast<long>(shortestMedianReach), static_cast<long>(longestMedianReach)));
}

std::size_t longestPeriod(double sampleRate) noexcept {
    return static_cast<std::size_t>(std::ceil(sampleRate / pitchFollowerLowestFrequency)) + 1;
}

/// The analysis covers a window of two longest periods plus one period of lags.
std::size_t fftSize(double sampleRate) noexcept { return nextPowerOfTwo(3 * longestPeriod(sampleRate)); }

double minimumAt(const PitchFollowerControls& controls, std::size_t frame) noexcept {
    return std::clamp(static_cast<double>(controls.minFreq.valueAt(frame)), pitchFollowerLowestFrequency, 2000.0);
}

double maximumAt(const PitchFollowerControls& controls, std::size_t frame, double minimum) noexcept {
    return std::max(std::clamp(static_cast<double>(controls.maxFreq.valueAt(frame)), 100.0, 4000.0), minimum * 1.01);
}

double mono(const AudioInput& input, std::ptrdiff_t frame) noexcept {
    const std::size_t channels = std::min(input.channelCount, maxAudioInputChannels);
    if (frame < 0 || channels == 0) {
        return 0.0;
    }
    double sum = 0.0;
    for (std::size_t channel = 0; channel < channels; ++channel) {
        sum += input.sample(channel, static_cast<std::size_t>(frame));
    }
    return sum / static_cast<double>(channels);
}

/// One YIN estimate centred on `centre`, written to `estimate`'s raw and confidence slots.
void analyse(const PitchFollowerControls& controls, const AudioInput& input, std::size_t centre, double* scratch,
             float* estimate) noexcept {
    const double sampleRate = controls.sampleRate;
    const std::size_t n = fftSize(sampleRate);
    const std::size_t longest = longestPeriod(sampleRate);
    double* aReal = scratch;
    double* aImaginary = aReal + n;
    double* bReal = aImaginary + n;
    double* bImaginary = bReal + n;
    const double* cosines = bImaginary + n;
    const double* sines = cosines + n / 2;
    double* energy = bImaginary + 2 * n;          // prefix sums of the span's squares
    double* normalised = energy + 3 * longest + 1;  // YIN's cumulative-mean-normalised difference

    const double minimum = minimumAt(controls, centre);
    const double maximum = maximumAt(controls, centre, minimum);
    const double threshold = std::clamp(static_cast<double>(controls.threshold.valueAt(centre)), 0.0, 1.0);
    const std::size_t maxPeriod = std::min(static_cast<std::size_t>(std::ceil(sampleRate / minimum)) + 1, longest);
    const std::size_t minPeriod = std::max<std::size_t>(2, static_cast<std::size_t>(std::floor(sampleRate / maximum)));
    const std::size_t window = 2 * maxPeriod;
    const std::size_t span = window + maxPeriod;
    // Centred: the span reaches as far ahead of the estimate's frame as behind it.
    const std::ptrdiff_t start = static_cast<std::ptrdiff_t>(centre) - static_cast<std::ptrdiff_t>(span / 2);

    estimate[rawSlot] = none;
    estimate[confidenceSlot] = 0.0f;
    for (std::size_t k = 0; k < maxCandidates; ++k) {
        estimate[candidateSlot + k] = none;
        estimate[costSlot + k] = 1.0f;
        estimate[routeSlot + k] = 0.0f;
        estimate[fromSlot + k] = 0.0f;
    }
    energy[0] = 0.0;
    for (std::size_t j = 0; j < n; ++j) {
        const double x = j < span ? mono(input, start + static_cast<std::ptrdiff_t>(j)) : 0.0;
        bReal[j] = x;
        bImaginary[j] = 0.0;
        aReal[j] = j < window ? x : 0.0;
        aImaginary[j] = 0.0;
        if (j < span) {
            energy[j + 1] = energy[j] + x * x;
        }
    }
    const double windowEnergy = energy[window];
    if (!(windowEnergy > 1e-9 * static_cast<double>(window))) {
        return;  // silence: no pitch, no confidence
    }

    // r(τ) = Σ a[j]·b[j + τ], the window against the span, by FFT (the span is at most n long, so
    // nothing wraps for the lags used).
    fft(aReal, aImaginary, n, cosines, sines);
    fft(bReal, bImaginary, n, cosines, sines);
    for (std::size_t k = 0; k < n; ++k) {
        const double real = aReal[k] * bReal[k] + aImaginary[k] * bImaginary[k];
        const double imaginary = aReal[k] * bImaginary[k] - aImaginary[k] * bReal[k];
        bReal[k] = real;
        bImaginary[k] = imaginary;
    }
    inverseFft(bReal, bImaginary, n, cosines, sines);

    // d(τ) = Σ (a[j] − b[j + τ])², then normalised by its running mean (YIN steps 2 and 3).
    normalised[0] = 1.0;
    double running = 0.0;
    for (std::size_t tau = 1; tau <= maxPeriod; ++tau) {
        const double shifted = energy[tau + window] - energy[tau];
        const double difference = std::max(windowEnergy + shifted - 2.0 * bReal[tau], 0.0);
        running += difference;
        normalised[tau] = running > 0.0 ? difference * static_cast<double>(tau) / running : 1.0;
    }

    // The first dip below the threshold, walked to its bottom; failing that, the lowest point. The
    // first dip, not the lowest, is what keeps YIN off the octave below.
    std::size_t best = 0;
    for (std::size_t tau = minPeriod; tau < maxPeriod; ++tau) {
        if (normalised[tau] < dipThreshold) {
            while (tau + 1 < maxPeriod && normalised[tau + 1] < normalised[tau]) {
                ++tau;
            }
            best = tau;
            break;
        }
    }
    if (best == 0) {
        best = minPeriod;
        for (std::size_t tau = minPeriod; tau < maxPeriod; ++tau) {
            if (normalised[tau] < normalised[best]) {
                best = tau;
            }
        }
    }
    double period = static_cast<double>(best);
    if (best > minPeriod && best + 1 < maxPeriod) {
        const double before = normalised[best - 1], at = normalised[best], after = normalised[best + 1];
        const double curvature = before - 2.0 * at + after;
        if (curvature > 0.0) {
            period += std::clamp(0.5 * (before - after) / curvature, -1.0, 1.0);
        }
    }
    const double confidence = std::clamp(1.0 - normalised[best], 0.0, 1.0);
    const double frequency = sampleRate / period;
    estimate[confidenceSlot] = static_cast<float>(confidence);
    if (confidence >= threshold && frequency >= minimum && frequency <= maximum && std::isfinite(frequency)) {
        estimate[rawSlot] = static_cast<float>(std::log2(frequency));
    }

    // Candidates for the whole-file path: the pick above, then the deepest other dips in range.
    if (std::isfinite(frequency) && frequency > 0.0) {
        estimate[candidateSlot] = static_cast<float>(std::log2(frequency));
        estimate[costSlot] = static_cast<float>(normalised[best]);
        std::size_t dips[maxCandidates];
        std::size_t dipCount = 0;
        for (std::size_t tau = minPeriod; tau + 1 <= maxPeriod && tau >= 1; ++tau) {
            const double value = normalised[tau];
            if (!(value <= normalised[tau - 1] && value < normalised[tau + 1] && value < candidateCeiling)) {
                continue;
            }
            std::size_t place = dipCount;
            if (dipCount == maxCandidates - 1) {
                if (!(value < normalised[dips[dipCount - 1]])) {
                    continue;
                }
                place = dipCount - 1;
            } else {
                ++dipCount;
            }
            while (place > 0 && normalised[dips[place - 1]] > value) {
                dips[place] = dips[place - 1];
                --place;
            }
            dips[place] = tau;
        }
        std::size_t used = 1;
        for (std::size_t d = 0; d < dipCount && used < maxCandidates; ++d) {
            const std::size_t tau = dips[d];
            double dipPeriod = static_cast<double>(tau);
            if (tau > minPeriod && tau + 1 < maxPeriod) {
                const double before = normalised[tau - 1], at = normalised[tau], after = normalised[tau + 1];
                const double curvature = before - 2.0 * at + after;
                if (curvature > 0.0) {
                    dipPeriod += std::clamp(0.5 * (before - after) / curvature, -1.0, 1.0);
                }
            }
            const double dipFrequency = sampleRate / dipPeriod;
            if (!(dipFrequency >= minimum && dipFrequency <= maximum) || !std::isfinite(dipFrequency)) {
                continue;
            }
            const float pitch = static_cast<float>(std::log2(dipFrequency));
            bool distinct = true;
            for (std::size_t k = 0; k < used; ++k) {
                if (std::abs(static_cast<double>(pitch) - static_cast<double>(estimate[candidateSlot + k])) < candidateSeparation) {
                    distinct = false;
                }
            }
            if (distinct) {
                estimate[candidateSlot + used] = pitch;
                estimate[costSlot + used] = static_cast<float>(normalised[tau]);
                ++used;
            }
        }
    }
}

/// Over each run of voiced estimates, the cheapest route through their candidates: each candidate's own cost plus
/// `octaveCost` per octave between neighbours. The chosen pitch replaces the raw one, so unvoiced estimates stay
/// unvoiced and an estimate keeps its own pick unless the route through its neighbours says otherwise.
void resolvePath(float* estimates, std::size_t count) noexcept {
    std::size_t index = 0;
    while (index < count) {
        if (!isPitch(estimates[index * floatsPerEstimate + rawSlot])) {
            ++index;
            continue;
        }
        const std::size_t first = index;
        while (index < count && isPitch(estimates[index * floatsPerEstimate + rawSlot])) {
            ++index;
        }
        const std::size_t end = index;
        for (std::size_t e = first; e < end; ++e) {
            float* now = estimates + e * floatsPerEstimate;
            for (std::size_t k = 0; k < maxCandidates; ++k) {
                if (!isPitch(now[candidateSlot + k])) {
                    now[routeSlot + k] = noRoute;
                    continue;
                }
                if (e == first) {
                    now[routeSlot + k] = now[costSlot + k];
                    continue;
                }
                const float* before = estimates + (e - 1) * floatsPerEstimate;
                float best = noRoute;
                std::size_t from = 0;
                for (std::size_t j = 0; j < maxCandidates; ++j) {
                    if (!(before[routeSlot + j] < noRoute)) {
                        continue;
                    }
                    const float jump = static_cast<float>(octaveCost) * std::abs(now[candidateSlot + k] - before[candidateSlot + j]);
                    const float total = before[routeSlot + j] + jump;
                    if (total < best) {
                        best = total;
                        from = j;
                    }
                }
                now[routeSlot + k] = best < noRoute ? now[costSlot + k] + best : noRoute;
                now[fromSlot + k] = static_cast<float>(from);
            }
        }
        const float* last = estimates + (end - 1) * floatsPerEstimate;
        std::size_t choice = 0;
        for (std::size_t k = 1; k < maxCandidates; ++k) {
            if (last[routeSlot + k] < last[routeSlot + choice]) {
                choice = k;
            }
        }
        for (std::size_t e = end; e-- > first;) {
            float* now = estimates + e * floatsPerEstimate;
            if (isPitch(now[candidateSlot + choice])) {
                now[rawSlot] = now[candidateSlot + choice];
            }
            choice = static_cast<std::size_t>(now[fromSlot + choice]);
        }
    }
}

/// The median of estimate `index`'s voiced neighbours, and the pitch held through what follows.
void resolve(float* estimates, std::size_t index, std::size_t count, std::size_t medianReach, bool path) noexcept {
    float* estimate = estimates + index * floatsPerEstimate;
    estimate[medianSlot] = none;
    if (path) {
        estimate[medianSlot] = estimate[rawSlot];
    } else if (isPitch(estimate[rawSlot])) {
        float values[2 * longestMedianReach + 1];
        std::size_t found = 0;
        const std::size_t first = index >= medianReach ? index - medianReach : 0;
        const std::size_t last = std::min(index + medianReach, count - 1);
        for (std::size_t neighbour = first; neighbour <= last; ++neighbour) {
            const float raw = estimates[neighbour * floatsPerEstimate + rawSlot];
            if (isPitch(raw)) {
                values[found++] = raw;
            }
        }
        std::sort(values, values + found);
        estimate[medianSlot] = values[found / 2];
    }
    const float previous = index > 0 ? estimates[(index - 1) * floatsPerEstimate + heldSlot] : none;
    estimate[heldSlot] = isPitch(estimate[medianSlot]) ? estimate[medianSlot] : previous;
}

/// An estimate's output value under the current settings.
double valueOf(const float* estimate, PitchFollowerOutput output, PitchFollowerUnvoiced unvoiced, double minimum,
               double maximum) noexcept {
    double pitch = estimate[medianSlot];
    if (!isPitch(estimate[medianSlot])) {
        if (unvoiced == PitchFollowerUnvoiced::zero) {
            return 0.0;
        }
        const bool holds = unvoiced == PitchFollowerUnvoiced::hold && isPitch(estimate[heldSlot]);
        pitch = holds ? estimate[heldSlot] : std::log2(minimum);
    }
    double value = 0.0;
    switch (output) {
    case PitchFollowerOutput::log:
        value = (pitch - std::log2(minimum)) / (std::log2(maximum) - std::log2(minimum));
        break;
    case PitchFollowerOutput::linear:
        value = (std::exp2(pitch) - minimum) / (maximum - minimum);
        break;
    case PitchFollowerOutput::note:
        value = (69.0 + 12.0 * (pitch - log2Of440)) / 127.0;
        break;
    }
    return std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.0;
}

} // namespace

std::size_t pitchFollowerHop(double sampleRate) noexcept {
    return hopFrames(sampleRate, hopSeconds);
}

std::size_t pitchFollowerHop(double sampleRate, double hopMilliseconds) noexcept {
    return hopFrames(sampleRate, hopMilliseconds / 1000.0);
}

std::size_t pitchFollowerEstimateCount(std::size_t frames, double sampleRate) noexcept {
    return frames == 0 ? 0 : (frames - 1) / pitchFollowerHop(sampleRate) + 2;
}

std::size_t pitchFollowerEstimateCount(std::size_t frames, double sampleRate, double hopMilliseconds) noexcept {
    return frames == 0 ? 0 : (frames - 1) / pitchFollowerHop(sampleRate, hopMilliseconds) + 2;
}

std::size_t pitchFollowerFloatsPerEstimate() noexcept { return floatsPerEstimate; }

std::size_t pitchFollowerScratchDoubles(double sampleRate) noexcept {
    if (!(sampleRate > 0.0) || !std::isfinite(sampleRate)) {
        return 0;
    }
    const std::size_t n = fftSize(sampleRate);
    const std::size_t longest = longestPeriod(sampleRate);
    // Four FFT arrays, the twiddles, the energy prefix and the normalised difference.
    return 5 * n + (3 * longest + 1) + (longest + 1);
}

void pitchFollowerPrepareScratch(double sampleRate, double* scratch) noexcept {
    if (scratch == nullptr || !(sampleRate > 0.0) || !std::isfinite(sampleRate)) {
        return;
    }
    const std::size_t n = fftSize(sampleRate);
    fftTwiddles(n, scratch + 4 * n, scratch + 4 * n + n / 2);
}

std::size_t pitchFollowerEstimatesNeeded(const PitchFollowerState& state, const PitchFollowerControls& controls,
                                         std::size_t estimateCount, std::size_t frameOffset, std::size_t count) noexcept {
    if (estimateCount == 0) {
        return 0;
    }
    if (controls.smoothing == PitchFollowerSmoothing::path) {
        return estimateCount;
    }
    if (count == 0) {
        return state.analysed;
    }
    const double hopSeconds = controls.hopMilliseconds / 1000.0;
    const std::size_t hop = hopFrames(controls.sampleRate, hopSeconds);
    const std::size_t reach = medianReachFor(hopSeconds);
    const std::size_t neededResolved = std::min((frameOffset + count - 1) / hop + 1, estimateCount - 1);
    return std::min(neededResolved + reach, estimateCount - 1) + 1;
}

void pitchFollowerAnalyse(const PitchFollowerControls& controls, const AudioInput& input, float* estimates,
                          std::size_t first, std::size_t last, double* scratch) noexcept {
    if (estimates == nullptr || scratch == nullptr) {
        return;
    }
    const std::size_t hop = hopFrames(controls.sampleRate, controls.hopMilliseconds / 1000.0);
    for (std::size_t index = first; index < last; ++index) {
        analyse(controls, input, index * hop, scratch, estimates + index * floatsPerEstimate);
    }
}

namespace {

/// The unglided output at `frame`: the neighbouring estimates' values, interpolated.
double targetAt(const PitchFollowerControls& controls, const float* estimates, std::size_t estimateCount,
                std::size_t hop, std::size_t frame) noexcept {
    const std::size_t a = std::min(frame / hop, estimateCount - 1);
    const std::size_t b = std::min(a + 1, estimateCount - 1);
    const double t = static_cast<double>(frame - std::min(frame, a * hop)) / static_cast<double>(hop);
    const float* first = estimates + a * floatsPerEstimate;
    const float* second = estimates + b * floatsPerEstimate;
    const double minimum = minimumAt(controls, frame);
    const double maximum = maximumAt(controls, frame, minimum);
    const auto output = choiceAt(controls.output, frame, controls.fixedOutput, 3);
    const auto unvoiced = choiceAt(controls.unvoiced, frame, controls.fixedUnvoiced, 3);
    const double from = valueOf(first, output, unvoiced, minimum, maximum);
    const double to = valueOf(second, output, unvoiced, minimum, maximum);
    return from + std::clamp(t, 0.0, 1.0) * (to - from);
}

double glideCoefficientFor(float glide, double sampleRate) noexcept {
    const double milliseconds = std::clamp(static_cast<double>(glide), 0.0, 500.0);
    return milliseconds > 0.0 ? std::exp(-1.0 / (milliseconds * 0.001 * sampleRate)) : 0.0;
}

/// Zero-phase Glide: the one-pole forward over the whole file, then backward over its own output.
void buildZeroPhaseGlide(const PitchFollowerControls& controls, const float* estimates, std::size_t estimateCount,
                         std::size_t hop) noexcept {
    float* buffer = controls.glideBuffer;
    const std::size_t frames = controls.glideFrames;
    const double sampleRate = controls.sampleRate;
    double level = 0.0;
    float lastGlide = -1;
    double coefficient = 0.0;
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const double target = targetAt(controls, estimates, estimateCount, hop, frame);
        if (const float glide = controls.glide.valueAt(frame); glide != lastGlide) {
            lastGlide = glide;
            coefficient = glideCoefficientFor(glide, sampleRate);
        }
        level = frame == 0 ? target : target + coefficient * (level - target);
        if (!std::isfinite(level)) {
            level = 0.0;
        }
        buffer[frame] = static_cast<float>(level);
    }
    lastGlide = -1;
    for (std::size_t frame = frames; frame-- > 0;) {
        if (const float glide = controls.glide.valueAt(frame); glide != lastGlide) {
            lastGlide = glide;
            coefficient = glideCoefficientFor(glide, sampleRate);
        }
        const double target = buffer[frame];
        level = frame + 1 == frames ? target : target + coefficient * (level - target);
        if (!std::isfinite(level)) {
            level = 0.0;
        }
        buffer[frame] = static_cast<float>(level);
    }
}

} // namespace

void renderPitchFollower(PitchFollowerState* state, const PitchFollowerControls& controls, const AudioInput& input,
                         float* estimates, std::size_t estimateCount, double* scratch, float* pitch,
                         float* confidence, std::size_t frameOffset, std::size_t count) noexcept {
    const double sampleRate = controls.sampleRate;
    const bool usable = state != nullptr && estimates != nullptr && scratch != nullptr && estimateCount > 0 &&
                        sampleRate > 0.0 && std::isfinite(sampleRate);
    if (!usable) {
        for (std::size_t i = 0; i < count; ++i) {
            if (pitch != nullptr) pitch[i] = 0.0f;
            if (confidence != nullptr) confidence[i] = 0.0f;
        }
        return;
    }
    const double hopSeconds = controls.hopMilliseconds / 1000.0;
    const std::size_t hop = hopFrames(sampleRate, hopSeconds);
    const std::size_t reach = medianReachFor(hopSeconds);
    const bool path = controls.smoothing == PitchFollowerSmoothing::path;
    const std::size_t n = fftSize(sampleRate);
    if (!state->twiddlesReady) {
        fftTwiddles(n, scratch + 4 * n, scratch + 4 * n + n / 2);
        state->twiddlesReady = true;
    }
    if (count == 0) {
        return;
    }

    // Everything this chunk reads: up to the estimate after its last frame, and the median's reach. The whole-file
    // path reads every estimate before the first frame.
    const std::size_t lastFrame = frameOffset + count - 1;
    std::size_t neededResolved = std::min(lastFrame / hop + 1, estimateCount - 1);
    std::size_t neededAnalysed = std::min(neededResolved + reach, estimateCount - 1);
    if (path) {
        neededResolved = estimateCount - 1;
        neededAnalysed = estimateCount - 1;
    }
    for (; state->analysed <= neededAnalysed; ++state->analysed) {
        analyse(controls, input, state->analysed * hop, scratch, estimates + state->analysed * floatsPerEstimate);
    }
    if (path && !state->pathResolved) {
        resolvePath(estimates, estimateCount);
        state->pathResolved = true;
    }
    for (; state->resolved <= neededResolved; ++state->resolved) {
        resolve(estimates, state->resolved, estimateCount, reach, path);
    }

    const bool zeroPhase = controls.glidePhase == PitchFollowerGlidePhase::zeroPhase && controls.glideBuffer != nullptr &&
                           controls.glideFrames > 0;
    if (zeroPhase && !state->glideBuilt) {
        // Needs every estimate: the backward pass starts at the end of the file.
        for (; state->analysed < estimateCount; ++state->analysed) {
            analyse(controls, input, state->analysed * hop, scratch, estimates + state->analysed * floatsPerEstimate);
        }
        if (path && !state->pathResolved) {
            resolvePath(estimates, estimateCount);
            state->pathResolved = true;
        }
        for (; state->resolved < estimateCount; ++state->resolved) {
            resolve(estimates, state->resolved, estimateCount, reach, path);
        }
        buildZeroPhaseGlide(controls, estimates, estimateCount, hop);
        state->glideBuilt = true;
    }

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const std::size_t a = std::min(frame / hop, estimateCount - 1);
        const std::size_t b = std::min(a + 1, estimateCount - 1);
        const double t = static_cast<double>(frame - std::min(frame, a * hop)) / static_cast<double>(hop);
        const float* first = estimates + a * floatsPerEstimate;
        const float* second = estimates + b * floatsPerEstimate;

        if (zeroPhase) {
            if (pitch != nullptr) {
                const float held = controls.glideBuffer[std::min(frame, controls.glideFrames - 1)];
                pitch[i] = std::isfinite(held) ? static_cast<float>(std::clamp(static_cast<double>(held), 0.0, 1.0)) : 0.0f;
            }
        } else {
            const double target = targetAt(controls, estimates, estimateCount, hop, frame);
            if (const float glide = controls.glide.valueAt(frame); glide != state->lastGlide) {
                state->lastGlide = glide;
                state->glideCoefficient = glideCoefficientFor(glide, sampleRate);
            }
            if (!state->started) {
                state->level = target;
                state->started = true;
            }
            state->level = target + state->glideCoefficient * (state->level - target);
            if (!std::isfinite(state->level)) {
                state->level = 0.0;
            }
            if (pitch != nullptr) {
                pitch[i] = static_cast<float>(std::clamp(state->level, 0.0, 1.0));
            }
        }
        if (confidence != nullptr) {
            const double c = first[confidenceSlot] + std::clamp(t, 0.0, 1.0) * (second[confidenceSlot] - first[confidenceSlot]);
            confidence[i] = std::isfinite(c) ? static_cast<float>(std::clamp(c, 0.0, 1.0)) : 0.0f;
        }
    }
}

} // namespace bake::dsp
