#include "BakeDSP/Conform.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

#include "BakeDSP/Stft.h"

namespace bake::dsp {

namespace {

constexpr double none = std::numeric_limits<double>::quiet_NaN();

/// Magnitudes of every STFT frame of `mono` (frame-major, `bins` each).
std::vector<float> magnitudes(const StftLayout& layout, const float* mono, std::size_t frames, std::size_t& count) {
    count = stftFrameCount(layout, frames);
    const std::size_t bins = stftBinCount(layout);
    std::vector<float> spectrum(stftSpectrumFloats(layout, 1));
    std::vector<double> scratch(stftScratchDoubles(layout));
    std::vector<float> out(count * bins);
    for (std::size_t frame = 0; frame < count; ++frame) {
        stftForward(layout, mono, frames, frame, 1, spectrum.data(), scratch.data());
        stftMagnitudes(spectrum.data(), 1, bins, out.data() + frame * bins);
    }
    return out;
}

/// The envelope's value at a fractional position (linear), 0 outside it.
double at(const std::vector<double>& e, double position) {
    if (position < 0) return 0;
    const auto i = static_cast<std::size_t>(position);
    if (i + 1 >= e.size()) return i < e.size() ? e[i] : 0;
    const double t = position - static_cast<double>(i);
    return e[i] * (1 - t) + e[i + 1] * t;
}

double autocorrelation(const std::vector<double>& e, double lag) {
    double sum = 0;
    for (std::size_t n = 0; n < e.size(); ++n) sum += e[n] * at(e, static_cast<double>(n) + lag);
    return sum;
}

} // namespace

double conformTempo(const float* mono, std::size_t frames, double sampleRate, double target) noexcept {
    if (mono == nullptr || frames == 0 || !(sampleRate > 0)) return none;
    try {
        StftLayout layout;
        layout.fftSize = 1024;
        layout.hop = 512;
        std::size_t count = 0;
        const auto mags = magnitudes(layout, mono, frames, count);
        const std::size_t bins = stftBinCount(layout);
        if (count < 8) return none;
        // Spectral flux on log magnitudes: how much louder each bin got since the last frame.
        std::vector<double> flux(count, 0.0);
        for (std::size_t f = 1; f < count; ++f) {
            double sum = 0;
            for (std::size_t b = 1; b < bins; ++b) {
                const double rise = std::log1p(100.0 * mags[f * bins + b]) - std::log1p(100.0 * mags[(f - 1) * bins + b]);
                if (rise > 0) sum += rise;
            }
            flux[f] = sum;
        }
        // Less its local mean (about half a second), so only the onsets stand out.
        const double rate = sampleRate / layout.hop;
        const auto half = static_cast<std::ptrdiff_t>(std::lround(0.25 * rate));
        std::vector<double> envelope(count, 0.0);
        for (std::size_t f = 0; f < count; ++f) {
            const auto lo = std::max<std::ptrdiff_t>(0, static_cast<std::ptrdiff_t>(f) - half);
            const auto hi = std::min<std::ptrdiff_t>(static_cast<std::ptrdiff_t>(count) - 1, static_cast<std::ptrdiff_t>(f) + half);
            double mean = 0;
            for (auto i = lo; i <= hi; ++i) mean += flux[static_cast<std::size_t>(i)];
            mean /= static_cast<double>(hi - lo + 1);
            envelope[f] = std::max(0.0, flux[f] - mean);
        }
        const double energy = autocorrelation(envelope, 0);
        if (!(energy > 1e-9)) return none;
        double best = 0, bestScore = 0;
        for (double bpm = 60.0; bpm <= 200.0 + 1e-9; bpm += 0.05) {
            const double lag = 60.0 * rate / bpm;
            double score = 0;
            for (int m = 1; m <= 4; ++m) score += autocorrelation(envelope, lag * m) / m;
            if (score > bestScore) {
                bestScore = score;
                best = bpm;
            }
        }
        // A clear beat repeats most of the onsets' energy at its period; a single hit or a pad doesn't.
        if (bestScore < 0.3 * energy * (1.0 + 1.0 / 2 + 1.0 / 3 + 1.0 / 4)) return none;
        if (target > 0) {
            while (best < target / std::sqrt(2.0)) best *= 2;
            while (best > target * std::sqrt(2.0)) best /= 2;
        }
        return best;
    } catch (...) {
        return none;
    }
}

int conformKey(const float* mono, std::size_t frames, double sampleRate) noexcept {
    if (mono == nullptr || frames == 0 || !(sampleRate > 0)) return -1;
    try {
        StftLayout layout;
        layout.fftSize = 4096;
        while (layout.fftSize > 512 && static_cast<std::size_t>(layout.fftSize) > frames) layout.fftSize /= 2;
        layout.hop = layout.fftSize / 4;
        std::size_t count = 0;
        const auto mags = magnitudes(layout, mono, frames, count);
        const std::size_t bins = stftBinCount(layout);
        const auto half = static_cast<long long>(layout.fftSize / 2);
        double chroma[12] = {};
        for (std::size_t f = 0; f < count; ++f) {
            const long long center = stftFrameCenter(layout, f);
            if (center < half || center + half > static_cast<long long>(frames)) continue;
            // Only spectral peaks, at their parabolically interpolated frequency: a window's main lobe is wider
            // than a semitone below about 400 Hz, so counting every bin would smear each note into its neighbours.
            const float* m = mags.data() + f * bins;
            for (std::size_t b = 1; b + 1 < bins; ++b) {
                if (!(m[b] > m[b - 1] && m[b] >= m[b + 1])) continue;
                const double a = m[b - 1], c = m[b], d = m[b + 1];
                const double denominator = a - 2 * c + d;
                const double offset = denominator != 0 ? 0.5 * (a - d) / denominator : 0;
                const double hz = (static_cast<double>(b) + offset) * sampleRate / layout.fftSize;
                if (hz < 55.0 || hz > 5'000.0) continue;
                const long note = std::lround(12.0 * std::log2(hz / 440.0)) + 9;  // 0 = C
                chroma[((note % 12) + 12) % 12] += c;
            }
        }
        // Krumhansl–Kessler profiles, tonic first.
        static constexpr double major[12] = {6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88};
        static constexpr double minor[12] = {6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17};
        auto correlation = [&](const double* profile, int root) {
            double mc = 0, mp = 0;
            for (int i = 0; i < 12; ++i) {
                mc += chroma[(i + root) % 12];
                mp += profile[i];
            }
            mc /= 12;
            mp /= 12;
            double num = 0, dc = 0, dp = 0;
            for (int i = 0; i < 12; ++i) {
                const double c = chroma[(i + root) % 12] - mc, p = profile[i] - mp;
                num += c * p;
                dc += c * c;
                dp += p * p;
            }
            return dc > 1e-18 ? num / std::sqrt(dc * dp) : 0.0;
        };
        int best = -1;
        double bestR = 0.6;
        for (int root = 0; root < 12; ++root) {
            if (const double r = correlation(major, root); r > bestR) { bestR = r; best = root; }
            if (const double r = correlation(minor, root); r > bestR) { bestR = r; best = 12 + root; }
        }
        return best;
    } catch (...) {
        return -1;
    }
}

} // namespace bake::dsp
