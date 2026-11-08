#include "BakeDSP/Resynthesis.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

#include "BakeDSP/Fft.h"

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;
constexpr double twoPi = 2.0 * pi;
constexpr double birthRelative = 1e-3;         // a new partial must be within 60 dB of the frame's loudest
constexpr double absoluteFloor = 1e-5;         // amplitude (-100 dBFS) below which nothing is a partial
constexpr double hysteresisDecibels = 24.0;    // how much further down a running partial may fall at hysteresis 1
constexpr double lobeBins = 3.0;               // a partial owns the bins within 3 of its centre (the Hann main lobe and its first sidelobes)
constexpr std::size_t analysisBlock = 32;

std::size_t size(int value) noexcept { return static_cast<std::size_t>(value); }

double wrapPi(double x) noexcept { return x - twoPi * std::floor((x + pi) / twoPi); }

std::uint32_t hash(std::uint32_t value) noexcept {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    value ^= value >> 16;
    return value;
}

/// Phase gained over one hop by a partial that holds `frequency` Hz (used to place the ramp rows of births and deaths).
double holdPhase(double frequency, double sampleRate, double hop) noexcept {
    return hop * twoPi * frequency / sampleRate;
}

struct Memory {
    double* stft;
    double* window;
    double* magnitude;
    double* peakFrequency;
    double* peakAmplitude;
    double* peakPhase;
    double* slotFrequency;
    double* slotAmplitude;
    double* slotPhase;
    int* slotActive;
    int* slotCooldown;
    unsigned* slotOrder;
    unsigned* peakOrder;
    unsigned char* peakUsed;
    unsigned char* binFlag;
    double* accumulator;   // last, so the others do not move with maxCount
    std::size_t bytes = 0;

    Memory(const ResynthesisSettings& settings, std::size_t maxCount, void* base) noexcept {
        const StftLayout layout = resynthesisLayout(settings);
        const std::size_t n = size(layout.fftSize);
        const std::size_t bins = stftBinCount(layout);
        const std::size_t slots = size(resynthesisPartialCount(settings));
        auto* origin = static_cast<unsigned char*>(base);
        std::size_t offset = 0;
        auto take = [&](auto* typed, std::size_t count) {
            using T = std::remove_pointer_t<decltype(typed)>;
            offset = (offset + 15) & ~static_cast<std::size_t>(15);
            T* pointer = origin == nullptr ? nullptr : reinterpret_cast<T*>(origin + offset);
            offset += count * sizeof(T);
            return pointer;
        };
        stft = take(stft, stftScratchDoubles(layout));
        window = take(window, n);
        magnitude = take(magnitude, bins);
        peakFrequency = take(peakFrequency, bins);
        peakAmplitude = take(peakAmplitude, bins);
        peakPhase = take(peakPhase, bins);
        slotFrequency = take(slotFrequency, slots);
        slotAmplitude = take(slotAmplitude, slots);
        slotPhase = take(slotPhase, slots);
        slotActive = take(slotActive, slots);
        slotCooldown = take(slotCooldown, slots);
        slotOrder = take(slotOrder, slots);
        peakOrder = take(peakOrder, bins);
        peakUsed = take(peakUsed, bins);
        binFlag = take(binFlag, bins);
        accumulator = take(accumulator, maxCount);
        bytes = offset;
    }
};

/// The fundamental of a table row: the lowest partial within 12 dB of the loudest.
double rowFundamental(const float* row, std::size_t slots) noexcept {
    float loudest = 0.0f;
    for (std::size_t s = 0; s < slots; ++s) {
        loudest = std::max(loudest, row[3 * s + 1]);
    }
    double lowest = 0.0;
    for (std::size_t s = 0; s < slots; ++s) {
        const double frequency = row[3 * s];
        if (row[3 * s + 1] >= 0.25f * loudest && row[3 * s + 1] > 0.0f && (lowest == 0.0 || frequency < lowest)) {
            lowest = frequency;
        }
    }
    return lowest;
}

double partialGain(PartialParity parity, double fundamental, double frequency, double tiltDecibelsPerOctave) noexcept {
    double gain = 1.0;
    if (tiltDecibelsPerOctave != 0.0 && frequency > 0.0) {
        gain *= std::pow(10.0, tiltDecibelsPerOctave * std::log2(frequency / 1000.0) / 20.0);
    }
    if (parity != PartialParity::all && fundamental > 0.0) {
        const long long number = std::max<long long>(1, std::llround(frequency / fundamental));
        const bool isOdd = (number & 1) != 0;
        if (isOdd != (parity == PartialParity::odd)) {
            gain = 0.0;
        }
    }
    return gain;
}

/// Adds the sines of `table` (for a `signalFrames`-sample signal) for samples `frameOffset … + count` into `accumulator`.
void renderSines(const ResynthesisSettings& settings, double sampleRate, const ParameterSignal& tilt, const float* table,
                 std::size_t slots, std::size_t signalFrames, double* accumulator, std::size_t frameOffset, std::size_t count) noexcept {
    const StftLayout layout = resynthesisLayout(settings);
    const std::size_t frames = stftFrameCount(layout, signalFrames);
    const long long hop = layout.hop;
    struct { double* accumulator; } m{accumulator};

    // Sines. Hop j runs from frame j's centre to frame j + 1's; each partial in it is a rotating phasor whose
    // rate and level move linearly, started afresh from the table row (so a chunk boundary changes nothing).
    const long long firstCentre = stftFrameCenter(layout, 0);
    const long long start = static_cast<long long>(frameOffset);
    const long long end = start + static_cast<long long>(count);
    auto floorDivide = [](long long a, long long b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    const long long firstHop = std::max<long long>(floorDivide(start - firstCentre, hop), 0);
    const long long lastHop = std::min<long long>(floorDivide(end - 1 - firstCentre, hop), static_cast<long long>(frames) - 2);
    auto tiltAt = [&](long long frame) {
        const long long centre = std::clamp<long long>(stftFrameCenter(layout, static_cast<std::size_t>(frame)), 0, static_cast<long long>(signalFrames) - 1);
        return static_cast<double>(tilt.valueAt(static_cast<std::size_t>(centre)));
    };
    for (long long j = firstHop; j <= lastHop; ++j) {
        const float* from = table + static_cast<std::size_t>(j) * slots * 3;
        const float* to = from + slots * 3;
        const long long centre = stftFrameCenter(layout, static_cast<std::size_t>(j));
        const long long length = std::min<long long>(hop, end - centre);
        const double tiltFrom = tiltAt(j), tiltTo = tiltAt(j + 1);
        const bool filtered = settings.parity != PartialParity::all;
        const double fundamentalFrom = filtered ? rowFundamental(from, slots) : 0.0;
        const double fundamentalTo = filtered ? rowFundamental(to, slots) : 0.0;
        for (std::size_t s = 0; s < slots; ++s) {
            const double amplitudeFrom = from[3 * s + 1], amplitudeTo = to[3 * s + 1];
            if (amplitudeFrom == 0.0 && amplitudeTo == 0.0) {
                continue;
            }
            const double frequencyFrom = from[3 * s], frequencyTo = to[3 * s];
            const double levelFrom = amplitudeFrom * partialGain(settings.parity, fundamentalFrom, frequencyFrom, tiltFrom);
            const double levelTo = amplitudeTo * partialGain(settings.parity, fundamentalTo, frequencyTo, tiltTo);
            if (levelFrom == 0.0 && levelTo == 0.0) {
                continue;
            }
            // McAulay-Quatieri cubic phase: the phase path through this hop starts and ends on the measured phase
            // and frequency of the two rows, taking the whole number of extra turns that makes it smoothest.
            const double segment = static_cast<double>(hop);
            const double omegaFrom = twoPi * frequencyFrom / sampleRate;
            const double omegaTo = twoPi * frequencyTo / sampleRate;
            const double phaseFrom = from[3 * s + 2];
            const double phaseTo = to[3 * s + 2];
            const double turns = std::round((phaseFrom + omegaFrom * segment - phaseTo + 0.5 * (omegaTo - omegaFrom) * segment) / twoPi);
            const double gap = phaseTo - phaseFrom - omegaFrom * segment + twoPi * turns;
            const double alpha = 3.0 * gap / (segment * segment) - (omegaTo - omegaFrom) / segment;
            const double beta = -2.0 * gap / (segment * segment * segment) + (omegaTo - omegaFrom) / (segment * segment);
            // Phase = phaseFrom + omegaFrom t + alpha t^2 + beta t^3; its steps have a constant third difference of 6 beta.
            double zr = std::cos(phaseFrom), zi = std::sin(phaseFrom);
            double wr = std::cos(omegaFrom + alpha + beta), wi = std::sin(omegaFrom + alpha + beta);
            double gr = std::cos(2.0 * alpha + 6.0 * beta), gi = std::sin(2.0 * alpha + 6.0 * beta);
            const double hr = std::cos(6.0 * beta), hi = std::sin(6.0 * beta);
            const double levelStep = (levelTo - levelFrom) / segment;
            for (long long t = 0; t < length; ++t) {
                const long long index = centre + t - start;
                if (index >= 0) {
                    m.accumulator[index] += (levelFrom + levelStep * static_cast<double>(t)) * zr;
                }
                const double nz = zr * wr - zi * wi;
                zi = zr * wi + zi * wr;
                zr = nz;
                const double nw = wr * gr - wi * gi;
                wi = wr * gi + wi * gr;
                wr = nw;
                const double ng = gr * hr - gi * hi;
                gi = gr * hi + gi * hr;
                gr = ng;
            }
        }
    }

}

/// Scale masks, bit n = semitone n above the root; as the Quantizer's.
unsigned scaleMask(QuantizerScale scale) noexcept {
    switch (scale) {
    case QuantizerScale::major: return 0b101010110101;
    case QuantizerScale::minor: return 0b010110101101;
    case QuantizerScale::pentatonic: return 0b001010010101;
    default: return 0b111111111111;
    }
}

/// The nearest note of the scale to `note` (MIDI semitones, fractional); ties go to the lower note.
double nearestScaleNote(double note, unsigned mask, int root) noexcept {
    const auto centre = static_cast<long long>(std::floor(note));
    double best = note;
    double bestDistance = std::numeric_limits<double>::infinity();
    for (long long candidate = centre - 6; candidate <= centre + 7; ++candidate) {
        const long long degree = ((candidate - root) % 12 + 12) % 12;
        if ((mask >> degree) & 1u) {
            const double distance = std::fabs(static_cast<double>(candidate) - note);
            if (distance < bestDistance) {
                bestDistance = distance;
                best = static_cast<double>(candidate);
            }
        }
    }
    return best;
}

struct TransformMemory {
    double* frequency;   // each slot's frequency in the previous output row (0: idle)
    double* phase;       // each slot's integrated phase, before the random offset
    double* offset;      // each slot's gliding quantize shift, semitones
    unsigned char* gliding;
    float* bRow;         // B's row interpolated at the position (3 floats per source slot)
    unsigned* rankA;     // active slots by frequency, for Morph and Cross
    unsigned* rankB;
    std::size_t bytes = 0;

    /// `slots` is the source partial count; the output can hold twice that.
    TransformMemory(std::size_t slots, void* base) noexcept {
        auto* origin = static_cast<unsigned char*>(base);
        std::size_t at = 0;
        auto take = [&](auto* typed, std::size_t count) {
            using T = std::remove_pointer_t<decltype(typed)>;
            at = (at + 15) & ~static_cast<std::size_t>(15);
            T* pointer = origin == nullptr ? nullptr : reinterpret_cast<T*>(origin + at);
            at += count * sizeof(T);
            return pointer;
        };
        frequency = take(frequency, 2 * slots);
        phase = take(phase, 2 * slots);
        offset = take(offset, 2 * slots);
        gliding = take(gliding, 2 * slots);
        bRow = take(bRow, 3 * slots);
        rankA = take(rankA, slots);
        rankB = take(rankB, slots);
        bytes = at;
    }
};

bool isNeutral(const ParameterSignal& signal) noexcept { return signal.modulation == nullptr && signal.base == 0.0f; }

/// Interpolates a table at a fractional frame into `out` (3 floats per slot, phase included). A slot's
/// free rows hold its ramp's frequency (or 0 if idle).
void interpolateRow(const float* table, std::size_t frames, std::size_t slots, double position, float* out) noexcept {
    const double clamped = std::clamp(position, 0.0, static_cast<double>(frames - 1));
    const auto i0 = static_cast<std::size_t>(clamped);
    const std::size_t i1 = std::min(i0 + 1, frames - 1);
    const double fraction = clamped - static_cast<double>(i0);
    const float* row0 = table + i0 * slots * 3;
    const float* row1 = table + i1 * slots * 3;
    for (std::size_t s = 0; s < slots; ++s) {
        const double f0 = row0[3 * s], f1 = row1[3 * s];
        const double a0 = row0[3 * s + 1], a1 = row1[3 * s + 1];
        out[3 * s] = static_cast<float>(f0 == 0.0 ? f1 : (f1 == 0.0 ? f0 : f0 + fraction * (f1 - f0)));
        out[3 * s + 1] = static_cast<float>(a0 + fraction * (a1 - a0));
        out[3 * s + 2] = static_cast<float>(row0[3 * s + 2] + fraction * wrapPi(row1[3 * s + 2] - row0[3 * s + 2]));
    }
}

/// The slots of `row` sounding (amplitude above 0), in frequency order, into `rank`; returns how many.
std::size_t rankByFrequency(const float* row, std::size_t slots, unsigned* rank) noexcept {
    std::size_t count = 0;
    for (std::size_t s = 0; s < slots; ++s) {
        if (row[3 * s + 1] > 0.0f && row[3 * s] > 0.0f) {
            rank[count++] = static_cast<unsigned>(s);
        }
    }
    std::sort(rank, rank + count, [row](unsigned a, unsigned b) { return row[3 * a] < row[3 * b] || (row[3 * a] == row[3 * b] && a < b); });
    return count;
}

/// B's spectral envelope at `frequency`: its partials' levels joined linearly in log frequency; past
/// its lowest and highest partial the level falls away over an octave.
double envelopeAt(const float* row, const unsigned* rank, std::size_t count, double frequency) noexcept {
    if (count == 0 || frequency <= 0) {
        return 0;
    }
    const double octave = std::log2(frequency);
    const auto frequencyOf = [&](std::size_t i) { return std::log2(static_cast<double>(row[3 * rank[i]])); };
    const auto levelOf = [&](std::size_t i) { return static_cast<double>(row[3 * rank[i] + 1]); };
    if (octave <= frequencyOf(0)) {
        return levelOf(0) * std::max(0.0, 1 - (frequencyOf(0) - octave));
    }
    if (octave >= frequencyOf(count - 1)) {
        return levelOf(count - 1) * std::max(0.0, 1 - (octave - frequencyOf(count - 1)));
    }
    std::size_t low = 0, high = count - 1;
    while (high - low > 1) {
        const std::size_t middle = (low + high) / 2;
        (frequencyOf(middle) <= octave ? low : high) = middle;
    }
    const double span = frequencyOf(high) - frequencyOf(low);
    const double t = span > 0 ? (octave - frequencyOf(low)) / span : 0;
    return levelOf(low) + t * (levelOf(high) - levelOf(low));
}

/// 0 below `split`, 1 above, smooth over a third of an octave around it.
double above(double frequency, double split) noexcept {
    if (frequency <= 0 || split <= 0) {
        return 0;
    }
    const double t = std::clamp((std::log2(frequency / split) + 1.0 / 6) * 3, 0.0, 1.0);
    return t * t * (3 - 2 * t);
}

} // namespace

StftLayout resynthesisLayout(const ResynthesisSettings& settings) noexcept {
    const std::size_t clamped = nextPowerOfTwo(static_cast<std::size_t>(std::clamp(settings.fftSize, 1024, 16384)));
    const int fftSize = static_cast<int>(std::min<std::size_t>(clamped, 16384));
    return StftLayout{fftSize, fftSize / 4};
}

SineHops resynthesisSineHops(const ResynthesisSettings& settings, std::size_t signalFrames, std::size_t frameOffset, std::size_t count) noexcept {
    SineHops hops;
    const StftLayout layout = resynthesisLayout(settings);
    const long long frames = static_cast<long long>(stftFrameCount(layout, signalFrames));
    hops.hop = layout.hop;
    hops.firstCentre = stftFrameCenter(layout, 0);
    hops.lastHop = frames - 2;
    if (count == 0 || frames < 2) {
        return hops;
    }
    const long long start = static_cast<long long>(frameOffset);
    const long long end = start + static_cast<long long>(count);
    auto floorDivide = [](long long a, long long b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    const long long firstHop = std::max<long long>(floorDivide(start - hops.firstCentre, hops.hop), 0);
    const long long lastHop = std::min<long long>(floorDivide(end - 1 - hops.firstCentre, hops.hop), hops.lastHop);
    hops.first = firstHop;
    hops.count = lastHop >= firstHop ? lastHop - firstHop + 1 : 0;
    return hops;
}

void resynthesisSineParams(const ResynthesisSettings& settings, double sampleRate, const ParameterSignal& tilt,
                           const float* table, std::size_t slots, std::size_t signalFrames, long long j,
                           float* entries, unsigned* active) noexcept {
    *active = 0;
    const StftLayout layout = resynthesisLayout(settings);
    const std::size_t frames = stftFrameCount(layout, signalFrames);
    if (j < 0 || j + 1 >= static_cast<long long>(frames)) {
        return;
    }
    const double segment = static_cast<double>(layout.hop);
    const float* from = table + static_cast<std::size_t>(j) * slots * 3;
    const float* to = from + slots * 3;
    auto tiltAt = [&](long long frame) {
        const long long centre = std::clamp<long long>(stftFrameCenter(layout, static_cast<std::size_t>(frame)), 0, static_cast<long long>(signalFrames) - 1);
        return static_cast<double>(tilt.valueAt(static_cast<std::size_t>(centre)));
    };
    const double tiltFrom = tiltAt(j), tiltTo = tiltAt(j + 1);
    const bool filtered = settings.parity != PartialParity::all;
    const double fundamentalFrom = filtered ? rowFundamental(from, slots) : 0.0;
    const double fundamentalTo = filtered ? rowFundamental(to, slots) : 0.0;
    unsigned written = 0;
    for (std::size_t s = 0; s < slots; ++s) {
        const double amplitudeFrom = from[3 * s + 1], amplitudeTo = to[3 * s + 1];
        if (amplitudeFrom == 0.0 && amplitudeTo == 0.0) {
            continue;
        }
        const double frequencyFrom = from[3 * s], frequencyTo = to[3 * s];
        const double levelFrom = amplitudeFrom * partialGain(settings.parity, fundamentalFrom, frequencyFrom, tiltFrom);
        const double levelTo = amplitudeTo * partialGain(settings.parity, fundamentalTo, frequencyTo, tiltTo);
        if (levelFrom == 0.0 && levelTo == 0.0) {
            continue;
        }
        // The same cubic phase path as renderSines, kept in turns so the GPU's floats only ever hold small numbers.
        const double omegaFrom = twoPi * frequencyFrom / sampleRate;
        const double omegaTo = twoPi * frequencyTo / sampleRate;
        const double phaseFrom = from[3 * s + 2];
        const double phaseTo = to[3 * s + 2];
        const double turns = std::round((phaseFrom + omegaFrom * segment - phaseTo + 0.5 * (omegaTo - omegaFrom) * segment) / twoPi);
        const double gap = phaseTo - phaseFrom - omegaFrom * segment + twoPi * turns;
        const double alpha = 3.0 * gap / (segment * segment) - (omegaTo - omegaFrom) / segment;
        const double beta = -2.0 * gap / (segment * segment * segment) + (omegaTo - omegaFrom) / (segment * segment);
        const double startTurns = phaseFrom / twoPi;
        const double rate = frequencyFrom / sampleRate;
        const float rateHigh = static_cast<float>(rate);
        float* entry = entries + static_cast<std::size_t>(written) * sineEntryFloats;
        entry[0] = static_cast<float>(startTurns - std::floor(startTurns));
        entry[1] = rateHigh;
        entry[2] = static_cast<float>(rate - static_cast<double>(rateHigh));
        entry[3] = static_cast<float>(alpha / twoPi);
        entry[4] = static_cast<float>(beta / twoPi);
        entry[5] = static_cast<float>(levelFrom);
        entry[6] = static_cast<float>((levelTo - levelFrom) / segment);
        entry[7] = 0.0f;
        ++written;
    }
    *active = written;
}

int resynthesisPartialCount(const ResynthesisSettings& settings) noexcept {
    return std::clamp(settings.partials, minimumPartials, maximumPartials);
}

std::size_t resynthesisTableFloats(const ResynthesisSettings& settings, std::size_t signalFrames) noexcept {
    return stftFrameCount(resynthesisLayout(settings), signalFrames) * size(resynthesisPartialCount(settings)) * 3;
}

std::size_t resynthesisScratchBytes(const ResynthesisSettings& settings, std::size_t maxCount) noexcept {
    return Memory(settings, maxCount, nullptr).bytes;
}

std::size_t resynthesisAnalysisWorkFloats(const ResynthesisSettings& settings) noexcept {
    return analysisBlock * 2 * stftBinCount(resynthesisLayout(settings));
}

std::size_t resynthesisRenderWorkFloats(const ResynthesisSettings& settings, std::size_t maxCount) noexcept {
    const StftLayout layout = resynthesisLayout(settings);
    const std::size_t frames = maxCount / size(layout.hop) + stftOverlap(layout) + 2;
    return frames * (2 * stftBinCount(layout) + size(layout.fftSize));
}

void resynthesisAnalyse(const ResynthesisSettings& settings, double sampleRate, const float* signal, std::size_t signalFrames,
                        float* table, void* scratch, float* work) noexcept {
    if (signal == nullptr || table == nullptr || scratch == nullptr || work == nullptr || !(sampleRate > 0) || signalFrames == 0) {
        return;
    }
    const StftLayout layout = resynthesisLayout(settings);
    const std::size_t n = size(layout.fftSize);
    const std::size_t bins = stftBinCount(layout);
    const std::size_t slots = size(resynthesisPartialCount(settings));
    const std::size_t frames = stftFrameCount(layout, signalFrames);
    const double hop = layout.hop;
    const double binHertz = sampleRate / static_cast<double>(n);
    const double hysteresis = std::clamp(settings.hysteresis, 0.0, 1.0);
    const double toleranceSemitones = 0.5 + 1.5 * hysteresis;
    const double continueFactor = std::pow(10.0, -hysteresisDecibels * hysteresis / 20.0);
    const double amplitudeScale = 4.0 / static_cast<double>(n);   // a sine of amplitude A reads A * n / 4 in a Hann-windowed bin

    Memory m(settings, 0, scratch);
    std::fill(table, table + frames * slots * 3, 0.0f);
    std::fill(m.slotActive, m.slotActive + slots, 0);
    std::fill(m.slotCooldown, m.slotCooldown + slots, 0);
    std::fill(m.slotFrequency, m.slotFrequency + slots, 0.0);
    std::fill(m.slotAmplitude, m.slotAmplitude + slots, 0.0);
    std::fill(m.slotPhase, m.slotPhase + slots, 0.0);

    auto setRow = [&](std::size_t frame, std::size_t slot, double frequency, double amplitude, double phase) {
        float* entry = table + (frame * slots + slot) * 3;
        entry[0] = static_cast<float>(frequency);
        entry[1] = static_cast<float>(amplitude);
        entry[2] = static_cast<float>(wrapPi(phase));
    };

    for (std::size_t first = 0; first < frames; first += analysisBlock) {
        const std::size_t blockCount = std::min(analysisBlock, frames - first);
        stftForward(layout, signal, signalFrames, first, blockCount, work, m.stft);
        for (std::size_t b = 0; b < blockCount; ++b) {
            const std::size_t frame = first + b;
            const float* spectrum = work + b * 2 * bins;

            double loudest = 0.0;
            for (std::size_t k = 0; k < bins; ++k) {
                m.magnitude[k] = std::hypot(static_cast<double>(spectrum[2 * k]), static_cast<double>(spectrum[2 * k + 1]));
                if (k > 0 && k + 1 < bins) {
                    loudest = std::max(loudest, m.magnitude[k]);
                }
            }
            const double birthAmplitude = std::max(loudest * amplitudeScale * birthRelative, absoluteFloor);
            const double continueAmplitude = birthAmplitude * continueFactor;

            // Spectral peaks, in frequency order, with the log-parabola refinement of frequency and height.
            std::size_t peaks = 0;
            for (std::size_t k = 1; k + 1 < bins; ++k) {
                const double centre = m.magnitude[k];
                if (!(centre > m.magnitude[k - 1] && centre >= m.magnitude[k + 1]) || centre * amplitudeScale < continueAmplitude) {
                    continue;
                }
                const double alpha = std::log(std::max(m.magnitude[k - 1], 1e-30));
                const double beta = std::log(std::max(centre, 1e-30));
                const double gamma = std::log(std::max(m.magnitude[k + 1], 1e-30));
                const double curvature = alpha - 2.0 * beta + gamma;
                const double offset = curvature < -1e-12 ? std::clamp(0.5 * (alpha - gamma) / curvature, -0.5, 0.5) : 0.0;
                m.peakFrequency[peaks] = (static_cast<double>(k) + offset) * binHertz;
                // The Hann window's response at a fractional bin offset is (n / 2) sinc(pi d) / (1 - d^2); dividing the
                // centre bin by it reads the sine's height without the scalloping loss.
                const double response = std::fabs(offset) < 1e-9 ? 1.0 : std::sin(pi * offset) / (pi * offset) / (1.0 - offset * offset);
                m.peakAmplitude[peaks] = 2.0 * centre / (0.5 * static_cast<double>(n) * response);
                // The frame is centred on sample index n / 2, so a sine's phase at the centre is arg(X) + pi * k.
                m.peakPhase[peaks] = std::atan2(static_cast<double>(spectrum[2 * k + 1]), static_cast<double>(spectrum[2 * k])) + ((k & 1) ? pi : 0.0);
                m.peakUsed[peaks] = 0;
                ++peaks;
            }

            for (std::size_t s = 0; s < slots; ++s) {
                if (m.slotCooldown[s] > 0) {
                    --m.slotCooldown[s];
                }
            }

            // Running partials claim the nearest free peak within the tolerance, loudest partial first.
            std::size_t running = 0;
            for (std::size_t s = 0; s < slots; ++s) {
                if (m.slotActive[s]) {
                    m.slotOrder[running++] = static_cast<unsigned>(s);
                }
            }
            std::sort(m.slotOrder, m.slotOrder + running, [&](unsigned a, unsigned c) {
                return m.slotAmplitude[a] > m.slotAmplitude[c] || (m.slotAmplitude[a] == m.slotAmplitude[c] && a < c);
            });
            for (std::size_t r = 0; r < running; ++r) {
                const std::size_t s = m.slotOrder[r];
                const double wanted = m.slotFrequency[s];
                std::ptrdiff_t left = std::lower_bound(m.peakFrequency, m.peakFrequency + peaks, wanted) - m.peakFrequency - 1;
                std::ptrdiff_t right = left + 1;
                while (left >= 0 && m.peakUsed[left]) --left;
                while (right < static_cast<std::ptrdiff_t>(peaks) && m.peakUsed[right]) ++right;
                auto distance = [&](std::ptrdiff_t index) {
                    return index < 0 || index >= static_cast<std::ptrdiff_t>(peaks)
                        ? std::numeric_limits<double>::infinity()
                        : std::fabs(12.0 * std::log2(m.peakFrequency[index] / wanted));
                };
                const double leftDistance = distance(left);
                const double rightDistance = distance(right);
                const std::ptrdiff_t best = leftDistance <= rightDistance ? left : right;
                if (std::min(leftDistance, rightDistance) <= toleranceSemitones) {
                    m.peakUsed[best] = 1;
                    const double frequency = m.peakFrequency[best];
                    const double phase = m.peakPhase[best];
                    m.slotFrequency[s] = frequency;
                    m.slotAmplitude[s] = m.peakAmplitude[best];
                    m.slotPhase[s] = wrapPi(phase);
                    setRow(frame, s, frequency, m.peakAmplitude[best], phase);
                } else {
                    // The track ends: this row holds its frequency and the phase it would have reached, at amplitude 0.
                    setRow(frame, s, wanted, 0.0, m.slotPhase[s] + holdPhase(wanted, sampleRate, hop));
                    m.slotActive[s] = 0;
                    m.slotCooldown[s] = 2;
                    m.slotAmplitude[s] = 0.0;
                }
            }

            // New partials: the loudest unclaimed peaks above the birth level take the lowest free slots.
            std::size_t candidates = 0;
            for (std::size_t p = 0; p < peaks; ++p) {
                if (!m.peakUsed[p] && m.peakAmplitude[p] >= birthAmplitude) {
                    m.peakOrder[candidates++] = static_cast<unsigned>(p);
                }
            }
            std::sort(m.peakOrder, m.peakOrder + candidates, [&](unsigned a, unsigned c) {
                return m.peakAmplitude[a] > m.peakAmplitude[c] || (m.peakAmplitude[a] == m.peakAmplitude[c] && a < c);
            });
            std::size_t slot = 0;
            for (std::size_t c = 0; c < candidates; ++c) {
                while (slot < slots && (m.slotActive[slot] || m.slotCooldown[slot] > 0)) ++slot;
                if (slot >= slots) break;
                const unsigned p = m.peakOrder[c];
                const double frequency = m.peakFrequency[p];
                m.slotActive[slot] = 1;
                m.slotFrequency[slot] = frequency;
                m.slotAmplitude[slot] = m.peakAmplitude[p];
                m.slotPhase[slot] = wrapPi(m.peakPhase[p]);
                setRow(frame, slot, frequency, m.peakAmplitude[p], m.peakPhase[p]);
                if (frame > 0) {
                    setRow(frame - 1, slot, frequency, 0.0, m.peakPhase[p] - holdPhase(frequency, sampleRate, hop));
                }
                ++slot;
            }
        }
    }
}

void resynthesisRender(const ResynthesisSettings& settings, double sampleRate,
                       const ParameterSignal& tilt, const ParameterSignal& balance,
                       const float* signal, std::size_t signalFrames, const float* table,
                       float* output, std::size_t frameOffset, std::size_t count,
                       unsigned noiseSeed, void* scratch, float* work) noexcept {
    resynthesisRenderWithSines(settings, sampleRate, tilt, balance, signal, signalFrames, table, output, frameOffset, count,
                               noiseSeed, scratch, work, nullptr);
}

void resynthesisRenderWithSines(const ResynthesisSettings& settings, double sampleRate,
                                const ParameterSignal& tilt, const ParameterSignal& balance,
                                const float* signal, std::size_t signalFrames, const float* table,
                                float* output, std::size_t frameOffset, std::size_t count,
                                unsigned noiseSeed, void* scratch, float* work, const float* sines) noexcept {
    if (output == nullptr || count == 0) {
        return;
    }
    if (signal == nullptr || table == nullptr || scratch == nullptr || work == nullptr || !(sampleRate > 0) || frameOffset >= signalFrames) {
        std::fill(output, output + count, 0.0f);
        return;
    }
    if (count > signalFrames - frameOffset) {
        std::fill(output + (signalFrames - frameOffset), output + count, 0.0f);
        count = signalFrames - frameOffset;
    }

    const StftLayout layout = resynthesisLayout(settings);
    const std::size_t n = size(layout.fftSize);
    const std::size_t bins = stftBinCount(layout);
    const std::size_t slots = size(resynthesisPartialCount(settings));
    const std::size_t frames = stftFrameCount(layout, signalFrames);
    const long long hop = layout.hop;
    const double binHertz = sampleRate / static_cast<double>(n);

    Memory m(settings, count, scratch);
    std::fill(m.accumulator, m.accumulator + count, 0.0);

    if (sines != nullptr) {
        std::copy(sines, sines + count, m.accumulator);
    } else {
        renderSines(settings, sampleRate, tilt, table, size(resynthesisPartialCount(settings)), signalFrames, m.accumulator, frameOffset, count);
    }

    // Residual noise: each covering frame's spectrum with the partials' bins removed, given random phases.
    bool noisy = false;
    for (std::size_t i = 0; i < count && !noisy; ++i) {
        noisy = balance.valueAt(frameOffset + i) > 0.0f;
    }
    if (noisy) {
        const StftFrameRange range = stftFramesCovering(layout, signalFrames, frameOffset, count);
        float* spectra = work;
        float* rows = spectra + range.count * 2 * bins;
        stftForward(layout, signal, signalFrames, range.first, range.count, spectra, m.stft);
        for (std::size_t j = 0; j < range.count; ++j) {
            const std::size_t frame = range.first + j;
            const float* row = table + frame * slots * 3;
            std::fill(m.binFlag, m.binFlag + bins, static_cast<unsigned char>(0));
            for (std::size_t s = 0; s < slots; ++s) {
                if (row[3 * s + 1] > 0.0f) {
                    const long long centreBin = std::llround(row[3 * s] / binHertz);
                    for (long long k = centreBin - static_cast<long long>(lobeBins); k <= centreBin + static_cast<long long>(lobeBins); ++k) {
                        if (k >= 0 && k < static_cast<long long>(bins)) {
                            m.binFlag[k] = 1;
                        }
                    }
                }
            }
            float* spectrum = spectra + j * 2 * bins;
            for (std::size_t k = 0; k < bins; ++k) {
                if (m.binFlag[k]) {
                    spectrum[2 * k] = 0.0f;
                    spectrum[2 * k + 1] = 0.0f;
                    continue;
                }
                const double magnitude = std::hypot(static_cast<double>(spectrum[2 * k]), static_cast<double>(spectrum[2 * k + 1]));
                const double angle = twoPi * static_cast<double>(hash(static_cast<std::uint32_t>(k) * 7919u + static_cast<std::uint32_t>(frame) * 104729u + noiseSeed * 15485863u)) / 4294967296.0;
                if (k == 0 || k + 1 == bins) {
                    spectrum[2 * k] = static_cast<float>(std::cos(angle) >= 0.0 ? magnitude : -magnitude);
                    spectrum[2 * k + 1] = 0.0f;
                } else {
                    spectrum[2 * k] = static_cast<float>(magnitude * std::cos(angle));
                    spectrum[2 * k + 1] = static_cast<float>(magnitude * std::sin(angle));
                }
            }
        }
        stftInverseRows(layout, spectra, range.count, rows, m.stft);
        stftWindow(layout, m.window);
        stftOverlapAdd(layout, m.window, rows, range.first, range.count, signalFrames, frameOffset, count, output);
    } else {
        std::fill(output, output + count, 0.0f);
    }

    // Random phases spread each frame's energy evenly across the frame instead of under its window, so a frame of
    // spectrum energy sum(w^2) * variance gives variance * 3/8 per sample; after the synthesis window, the sum over the
    // overlapping frames and the division by sum(w^2) twice (once in the overlap-add), the noise has 3/8 / sum(w^2) = 1 / overlap
    // of the power it should. So it needs sqrt(overlap) times the gain.
    const double noiseCompensation = std::sqrt(static_cast<double>(stftOverlap(layout)));
    for (std::size_t i = 0; i < count; ++i) {
        const double b = std::clamp(static_cast<double>(balance.valueAt(frameOffset + i)), 0.0, 1.0);
        const double sineGain = std::min(1.0, 2.0 * (1.0 - b));
        const double noiseGain = std::min(1.0, 2.0 * b) * noiseCompensation;
        const double value = sineGain * m.accumulator[i] + noiseGain * static_cast<double>(output[i]);
        output[i] = std::isfinite(value) ? static_cast<float>(value) : 0.0f;
    }
}

bool resynthesisTransformIsNeutral(const ResynthesisTransform& transform) noexcept {
    return transform.stretch == 1.0 && !transform.freeze.isWired() && isNeutral(transform.pitch) && isNeutral(transform.crystallize)
        && isNeutral(transform.quantize) && isNeutral(transform.phaseRandomize) && transform.mode == ResynthesisMode::off;
}

int resynthesisOutputSlots(const ResynthesisSettings& settings, const ResynthesisTransform& transform) noexcept {
    const int slots = resynthesisPartialCount(settings);
    return transform.mode == ResynthesisMode::morph || transform.mode == ResynthesisMode::splice ? 2 * slots : slots;
}

std::size_t resynthesisOutputTableFloats(const ResynthesisSettings& settings, const ResynthesisTransform& transform,
                                         std::size_t outputFrames) noexcept {
    return stftFrameCount(resynthesisLayout(settings), outputFrames) * size(resynthesisOutputSlots(settings, transform)) * 3;
}

std::size_t resynthesisNoiseMapFloats(const ResynthesisSettings& settings, std::size_t outputFrames) noexcept {
    return stftFrameCount(resynthesisLayout(settings), outputFrames) * resynthesisNoiseMapStride;
}

std::size_t resynthesisTransformScratchBytes(const ResynthesisSettings& settings) noexcept {
    return TransformMemory(size(resynthesisPartialCount(settings)), nullptr).bytes;
}

void resynthesisTransformTable(const ResynthesisSettings& settings, double sampleRate, const ResynthesisTransform& transform,
                               const float* sourceTable, std::size_t sourceFrames, const float* bTable, std::size_t bFrames,
                               float* table, std::size_t outputFrames, float* noiseMap, void* scratch) noexcept {
    if (sourceTable == nullptr || table == nullptr || noiseMap == nullptr || scratch == nullptr || !(sampleRate > 0)
        || sourceFrames == 0 || outputFrames == 0) {
        return;
    }
    const StftLayout layout = resynthesisLayout(settings);
    const std::size_t slots = size(resynthesisPartialCount(settings));
    const std::size_t sourceCount = stftFrameCount(layout, sourceFrames);
    const std::size_t outputCount = stftFrameCount(layout, outputFrames);
    const bool second = bTable != nullptr && bFrames > 0 && transform.mode != ResynthesisMode::off;
    const ResynthesisMode mode = second ? transform.mode : ResynthesisMode::off;
    const std::size_t bCount = second ? stftFrameCount(layout, bFrames) : 0;
    const std::size_t outSlots = mode == ResynthesisMode::morph || mode == ResynthesisMode::splice ? 2 * slots : slots;
    const double hop = layout.hop;
    const double hopSeconds = hop / sampleRate;
    const double nyquist = 0.49 * sampleRate;
    const double stretch = transform.stretch > 0 ? transform.stretch : 1.0;
    const unsigned mask = scaleMask(transform.scale);
    TransformMemory m(slots, scratch);
    std::fill(m.frequency, m.frequency + outSlots, 0.0);
    std::fill(m.phase, m.phase + outSlots, 0.0);
    std::fill(m.offset, m.offset + outSlots, 0.0);
    std::fill(m.gliding, m.gliding + outSlots, static_cast<unsigned char>(0));

    bool frozen = false;
    double frozenPosition = 0;
    double freezeGain = 1;
    const double lastSource = static_cast<double>(sourceCount - 1);
    for (std::size_t j = 0; j < outputCount; ++j) {
        const auto centre = static_cast<std::size_t>(std::clamp<long long>(stftFrameCenter(layout, j), 0, static_cast<long long>(outputFrames) - 1));
        // Where in the source this frame plays: frame ÷ stretch, held while frozen.
        double position = static_cast<double>(j) / stretch;
        if (transform.freeze.isWired() && transform.freeze.valueAt(centre) > 0.5f) {
            if (!frozen) {
                frozen = true;
                frozenPosition = position;
                freezeGain = 1;
            }
            position = frozenPosition;
        } else {
            frozen = false;
            freezeGain = 1;
        }
        float* out = table + j * outSlots * 3;
        interpolateRow(sourceTable, sourceCount, slots, std::min(position, lastSource), out);
        if (outSlots > slots) {
            std::fill(out + slots * 3, out + outSlots * 3, 0.0f);
        }

        // The second input, at the same position.
        const double amount = std::clamp(static_cast<double>(transform.amount.valueAt(centre)), 0.0, 1.0);
        double bNoise = 0;
        if (second) {
            interpolateRow(bTable, bCount, slots, std::min(position, static_cast<double>(bCount - 1)), m.bRow);
            switch (mode) {
            case ResynthesisMode::cross: {
                // The input's partials at the levels of B's spectral envelope.
                const std::size_t count = rankByFrequency(m.bRow, slots, m.rankB);
                for (std::size_t s = 0; s < slots; ++s) {
                    if (out[3 * s] > 0.0f) {
                        const double level = out[3 * s + 1];
                        out[3 * s + 1] = static_cast<float>(level + amount * (envelopeAt(m.bRow, m.rankB, count, out[3 * s]) - level));
                    }
                }
                break;
            }
            case ResynthesisMode::morph: {
                // Partials paired by frequency order glide together (in the input's slot, so one phase);
                // the unpaired fade out (the input's) or in (B's, in the second bank).
                const std::size_t countA = rankByFrequency(out, slots, m.rankA);
                const std::size_t countB = rankByFrequency(m.bRow, slots, m.rankB);
                const std::size_t pairs = std::min(countA, countB);
                for (std::size_t s = 0; s < slots; ++s) {
                    out[3 * s + 1] *= static_cast<float>(1 - amount);
                    float* b = out + (slots + s) * 3;
                    b[0] = m.bRow[3 * s];
                    b[1] = static_cast<float>(amount * m.bRow[3 * s + 1]);
                    b[2] = m.bRow[3 * s + 2];
                }
                for (std::size_t i = 0; i < pairs; ++i) {
                    float* a = out + m.rankA[i] * 3;
                    const float* b = m.bRow + m.rankB[i] * 3;
                    const double levelA = a[1] / std::max(1 - amount, 1e-12);
                    a[0] = static_cast<float>(std::exp2(std::log2(static_cast<double>(a[0])) + amount * (std::log2(static_cast<double>(b[0])) - std::log2(static_cast<double>(a[0])))));
                    a[1] = static_cast<float>((1 - amount) * levelA + amount * b[1]);
                    out[(slots + m.rankB[i]) * 3 + 1] = 0.0f;
                }
                break;
            }
            case ResynthesisMode::splice: {
                // The input below Split, B above it (in the second bank), crossing over a third of an octave.
                const double split = std::max(static_cast<double>(transform.split.valueAt(centre)), 1.0);
                for (std::size_t s = 0; s < slots; ++s) {
                    out[3 * s + 1] *= static_cast<float>(1 - amount * above(out[3 * s], split));
                    float* b = out + (slots + s) * 3;
                    b[0] = m.bRow[3 * s];
                    b[1] = static_cast<float>(amount * above(m.bRow[3 * s], split) * m.bRow[3 * s + 1]);
                    b[2] = m.bRow[3 * s + 2];
                }
                break;
            }
            case ResynthesisMode::swapNoise:
                bNoise = amount;
                break;
            case ResynthesisMode::off:
                break;
            }
        }

        const double fundamental = rowFundamental(out, outSlots);
        const double ratio = std::exp2(std::clamp(static_cast<double>(transform.pitch.valueAt(centre)), -48.0, 48.0) / 12);
        const double crystallize = std::clamp(static_cast<double>(transform.crystallize.valueAt(centre)), 0.0, 1.0);
        const double quantize = std::clamp(static_cast<double>(transform.quantize.valueAt(centre)), 0.0, 1.0);
        const double glideSeconds = std::max(static_cast<double>(transform.glide.valueAt(centre)), 0.0) / 1000;
        const double glideStep = glideSeconds > 0 ? 1 - std::exp(-hopSeconds / glideSeconds) : 1.0;
        const double randomize = std::clamp(static_cast<double>(transform.phaseRandomize.valueAt(centre)), 0.0, 1.0);
        for (std::size_t s = 0; s < outSlots; ++s) {
            double frequency = out[3 * s];
            double amplitude = out[3 * s + 1];
            if (frequency <= 0.0) {
                out[3 * s] = 0.0f;
                out[3 * s + 1] = 0.0f;
                out[3 * s + 2] = 0.0f;
                m.frequency[s] = 0.0;
                m.gliding[s] = 0;
                continue;
            }
            if (crystallize > 0 && fundamental > 0) {
                const double harmonic = std::max(1.0, std::round(frequency / fundamental)) * fundamental;
                frequency += crystallize * (harmonic - frequency);
            }
            frequency *= ratio;
            // The applied shift glides (so do changes of Quantize itself); a partial is born on its shift.
            const double note = 69 + 12 * std::log2(frequency / 440);
            const double shift = quantize > 0 ? quantize * (nearestScaleNote(note, mask, transform.root) - note) : 0.0;
            if (!m.gliding[s]) {
                m.offset[s] = shift;
                m.gliding[s] = 1;
            } else {
                m.offset[s] += (shift - m.offset[s]) * glideStep;
            }
            if (m.offset[s] != 0.0) {
                frequency *= std::exp2(m.offset[s] / 12);
            }
            if (frequency >= nyquist) {
                amplitude = 0;
            }
            // Phases from integrated frequency: a slot coming alive starts on the analysed phase.
            if (m.frequency[s] == 0.0) {
                m.phase[s] = out[3 * s + 2];
            } else {
                m.phase[s] = wrapPi(m.phase[s] + pi * hop * (m.frequency[s] + frequency) / sampleRate);
            }
            m.frequency[s] = frequency;
            const double offset = randomize * twoPi * static_cast<double>(hash(static_cast<std::uint32_t>(s) * 2654435761u ^ (transform.seed * 40503u + 17u))) / 4294967296.0;
            out[3 * s] = static_cast<float>(frequency);
            out[3 * s + 1] = static_cast<float>(amplitude * freezeGain);
            out[3 * s + 2] = static_cast<float>(wrapPi(m.phase[s] + offset));
        }
        float* map = noiseMap + j * resynthesisNoiseMapStride;
        map[0] = static_cast<float>(std::round(std::min(position, lastSource)));
        map[1] = static_cast<float>(ratio);
        map[2] = static_cast<float>(freezeGain);
        map[3] = static_cast<float>(bNoise);
        map[4] = second ? static_cast<float>(std::round(std::min(position, static_cast<double>(bCount - 1)))) : 0.0f;
        if (frozen) {
            freezeGain *= std::pow(10.0, -std::max(static_cast<double>(transform.decay.valueAt(centre)), 0.0) * hopSeconds / 20);
        }
    }
}

namespace {

/// A frame's residual magnitudes: the spectrum of `source` frame `frame` with its partials' bins removed.
void residualMagnitudes(const StftLayout& layout, double sampleRate, std::size_t slots, const float* signal, std::size_t signalFrames,
                        const float* table, std::size_t frame, float* spectrum, double* magnitude, unsigned char* flag, double* stft) noexcept {
    const std::size_t bins = stftBinCount(layout);
    const double binHertz = sampleRate / static_cast<double>(layout.fftSize);
    stftForward(layout, signal, signalFrames, frame, 1, spectrum, stft);
    const float* row = table + frame * slots * 3;
    std::fill(flag, flag + bins, static_cast<unsigned char>(0));
    for (std::size_t s = 0; s < slots; ++s) {
        if (row[3 * s + 1] > 0.0f) {
            const long long centreBin = std::llround(row[3 * s] / binHertz);
            for (long long k = centreBin - static_cast<long long>(lobeBins); k <= centreBin + static_cast<long long>(lobeBins); ++k) {
                if (k >= 0 && k < static_cast<long long>(bins)) {
                    flag[k] = 1;
                }
            }
        }
    }
    for (std::size_t k = 0; k < bins; ++k) {
        magnitude[k] = flag[k] ? 0.0 : std::hypot(static_cast<double>(spectrum[2 * k]), static_cast<double>(spectrum[2 * k + 1]));
    }
}

} // namespace

void resynthesisRenderTransformed(const ResynthesisSettings& settings, double sampleRate, const ResynthesisTransform& transform,
                                  const ParameterSignal& tilt, const ParameterSignal& balance,
                                  const float* signal, std::size_t signalFrames, const float* sourceTable,
                                  const float* bSignal, std::size_t bFrames, const float* bTable,
                                  const float* table, const float* noiseMap, std::size_t outputFrames,
                                  float* output, std::size_t frameOffset, std::size_t count,
                                  unsigned noiseSeed, void* scratch, float* work) noexcept {
    resynthesisRenderTransformedWithSines(settings, sampleRate, transform, tilt, balance, signal, signalFrames, sourceTable,
                                          bSignal, bFrames, bTable, table, noiseMap, outputFrames, output, frameOffset, count,
                                          noiseSeed, scratch, work, nullptr);
}

void resynthesisRenderTransformedWithSines(const ResynthesisSettings& settings, double sampleRate, const ResynthesisTransform& transform,
                                           const ParameterSignal& tilt, const ParameterSignal& balance,
                                           const float* signal, std::size_t signalFrames, const float* sourceTable,
                                           const float* bSignal, std::size_t bFrames, const float* bTable,
                                           const float* table, const float* noiseMap, std::size_t outputFrames,
                                           float* output, std::size_t frameOffset, std::size_t count,
                                           unsigned noiseSeed, void* scratch, float* work, const float* sines) noexcept {
    if (output == nullptr || count == 0) {
        return;
    }
    if (signal == nullptr || sourceTable == nullptr || table == nullptr || noiseMap == nullptr || scratch == nullptr
        || work == nullptr || !(sampleRate > 0) || signalFrames == 0 || frameOffset >= outputFrames) {
        std::fill(output, output + count, 0.0f);
        return;
    }
    if (count > outputFrames - frameOffset) {
        std::fill(output + (outputFrames - frameOffset), output + count, 0.0f);
        count = outputFrames - frameOffset;
    }
    const StftLayout layout = resynthesisLayout(settings);
    const std::size_t bins = stftBinCount(layout);
    const std::size_t slots = size(resynthesisPartialCount(settings));
    const std::size_t sourceCount = stftFrameCount(layout, signalFrames);
    const bool second = bSignal != nullptr && bTable != nullptr && bFrames > 0;
    const std::size_t bCount = second ? stftFrameCount(layout, bFrames) : 0;
    const std::size_t outSlots = second ? size(resynthesisOutputSlots(settings, transform)) : slots;

    Memory m(settings, count, scratch);
    std::fill(m.accumulator, m.accumulator + count, 0.0);
    if (sines != nullptr) {
        std::copy(sines, sines + count, m.accumulator);
    } else {
        renderSines(settings, sampleRate, tilt, table, outSlots, outputFrames, m.accumulator, frameOffset, count);
    }

    // Residual noise: each output frame takes the residual of the source frame the noise map names
    // (blended toward B's by Swap Noise), its bins moved by the pitch ratio and scaled by the freeze
    // gain, with random phases.
    bool noisy = false;
    for (std::size_t i = 0; i < count && !noisy; ++i) {
        noisy = balance.valueAt(frameOffset + i) > 0.0f;
    }
    if (noisy) {
        const StftFrameRange range = stftFramesCovering(layout, outputFrames, frameOffset, count);
        float* spectra = work;
        float* rows = spectra + range.count * 2 * bins;
        for (std::size_t j = 0; j < range.count; ++j) {
            const std::size_t frame = range.first + j;
            const float* map = noiseMap + frame * resynthesisNoiseMapStride;
            const auto source = static_cast<std::size_t>(std::clamp(static_cast<double>(map[0]), 0.0, static_cast<double>(sourceCount - 1)));
            const double ratio = map[1] > 0.0f ? map[1] : 1.0;
            const double gain = map[2];
            const double bShare = second ? std::clamp(static_cast<double>(map[3]), 0.0, 1.0) : 0.0;
            float* spectrum = spectra + j * 2 * bins;
            if (bShare < 1) {
                residualMagnitudes(layout, sampleRate, slots, signal, signalFrames, sourceTable, source, spectrum, m.magnitude, m.binFlag, m.stft);
            } else {
                std::fill(m.magnitude, m.magnitude + bins, 0.0);
            }
            if (bShare > 0) {
                // B's residual in the peak scratch (free during rendering), then blended in.
                const auto bSource = static_cast<std::size_t>(std::clamp(static_cast<double>(map[4]), 0.0, static_cast<double>(bCount - 1)));
                residualMagnitudes(layout, sampleRate, slots, bSignal, bFrames, bTable, bSource, spectrum, m.peakAmplitude, m.binFlag, m.stft);
                for (std::size_t k = 0; k < bins; ++k) {
                    m.magnitude[k] = (1 - bShare) * m.magnitude[k] + bShare * m.peakAmplitude[k];
                }
            }
            for (std::size_t k = 0; k < bins; ++k) {
                // Bin k reads the residual at k / ratio (linear between bins); above the source's top bin is silent.
                const double from = static_cast<double>(k) / ratio;
                const auto below = static_cast<std::size_t>(from);
                double magnitude = 0;
                if (below + 1 < bins) {
                    const double t = from - static_cast<double>(below);
                    magnitude = m.magnitude[below] + t * (m.magnitude[below + 1] - m.magnitude[below]);
                } else if (below + 1 == bins) {
                    magnitude = m.magnitude[below];
                }
                magnitude *= gain;
                const double angle = twoPi * static_cast<double>(hash(static_cast<std::uint32_t>(k) * 7919u + static_cast<std::uint32_t>(frame) * 104729u + noiseSeed * 15485863u)) / 4294967296.0;
                if (k == 0 || k + 1 == bins) {
                    spectrum[2 * k] = static_cast<float>(std::cos(angle) >= 0.0 ? magnitude : -magnitude);
                    spectrum[2 * k + 1] = 0.0f;
                } else {
                    spectrum[2 * k] = static_cast<float>(magnitude * std::cos(angle));
                    spectrum[2 * k + 1] = static_cast<float>(magnitude * std::sin(angle));
                }
            }
        }
        stftInverseRows(layout, spectra, range.count, rows, m.stft);
        stftWindow(layout, m.window);
        stftOverlapAdd(layout, m.window, rows, range.first, range.count, outputFrames, frameOffset, count, output);
    } else {
        std::fill(output, output + count, 0.0f);
    }

    const double noiseCompensation = std::sqrt(static_cast<double>(stftOverlap(layout)));
    for (std::size_t i = 0; i < count; ++i) {
        const double b = std::clamp(static_cast<double>(balance.valueAt(frameOffset + i)), 0.0, 1.0);
        const double sineGain = std::min(1.0, 2.0 * (1.0 - b));
        const double noiseGain = std::min(1.0, 2.0 * b) * noiseCompensation;
        const double value = sineGain * m.accumulator[i] + noiseGain * static_cast<double>(output[i]);
        output[i] = std::isfinite(value) ? static_cast<float>(value) : 0.0f;
    }
}

} // namespace bake::dsp
