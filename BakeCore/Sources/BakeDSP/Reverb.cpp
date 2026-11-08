#include "BakeDSP/Reverb.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

bool isPrime(std::uint64_t n) noexcept {
    if (n < 2) return false;
    if (n % 2 == 0) return n == 2;
    for (std::uint64_t d = 3; d * d <= n; d += 2) if (n % d == 0) return false;
    return true;
}

std::uint64_t nextPrime(std::uint64_t n) noexcept {
    while (!isPrime(n)) ++n;
    return n;
}

std::uint64_t mixBits(std::uint64_t x) noexcept {
    x += 0x9E3779B97F4A7C15ull;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
    return x ^ (x >> 31);
}

/// The diffusers' lengths: four all-passes, a little different per channel, scaled to the sample rate.
void diffuserLengths(int channel, double sampleRate, std::size_t* out) noexcept {
    static const double base[4] = {142, 107, 379, 277};
    for (int i = 0; i < 4; ++i) {
        const double scaled = base[i] * sampleRate / 44100.0 * (1.0 + 0.037 * channel);
        out[i] = static_cast<std::size_t>(nextPrime(static_cast<std::uint64_t>(std::max(std::llround(scaled), 5ll))));
    }
}

/// A uniform number in [0, 1) from a hash.
inline double unit(std::uint64_t x) noexcept {
    return static_cast<double>(mixBits(x) >> 11) / 9007199254740992.0;
}

/// The ring at an absolute (possibly fractional) frame, 4-point Hermite. Frames not yet written read as 0.
inline double readRing(const float* line, std::size_t length, double position) noexcept {
    const double floor = std::floor(position);
    const double t = position - floor;
    const long long base = static_cast<long long>(floor);
    const long long size = static_cast<long long>(length);
    auto at = [&](long long frame) {
        long long index = frame % size;
        if (index < 0) index += size;
        return static_cast<double>(line[index]);
    };
    const double y0 = at(base - 1), y1 = at(base), y2 = at(base + 1), y3 = at(base + 2);
    const double c1 = 0.5 * (y2 - y0);
    const double c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    const double c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    return ((c3 * t + c2) * t + c1) * t + y1;
}

} // namespace

std::size_t reverbEarlyFrames(double size, double sampleRate) noexcept {
    return static_cast<std::size_t>(std::ceil(0.075 * std::max(size, 0.01) * sampleRate)) + 16;
}

void reverbEarlyDesign(double size, int channel, double sampleRate, std::size_t* frames, double* gains) noexcept {
    const double scale = std::max(size, 0.01);
    const double count = static_cast<double>(reverbEarlyTapCount);
    double energy = 0;
    std::size_t previous = 0;
    for (std::size_t k = 0; k < reverbEarlyTapCount; ++k) {
        const double u = unit(31337 + 131 * static_cast<std::uint64_t>(k) + 977 * static_cast<std::uint64_t>(channel));
        const double seconds = (0.003 + 0.072 * (static_cast<double>(k) + u) / count) * scale;
        std::size_t reach = static_cast<std::size_t>(std::max(std::llround(seconds * sampleRate), 2ll));
        reach = std::max(reach, previous + 1);
        frames[k] = reach;
        previous = reach;
        const double amplitude = std::exp(-2.0 * (static_cast<double>(k) + 0.5) / count);
        const bool negative = (mixBits(4242 + 17 * static_cast<std::uint64_t>(k) + 613 * static_cast<std::uint64_t>(channel)) & 1) != 0;
        gains[k] = negative ? -amplitude : amplitude;
        energy += amplitude * amplitude;
    }
    const double norm = 1.0 / std::sqrt(energy);
    for (std::size_t k = 0; k < reverbEarlyTapCount; ++k) gains[k] *= norm;
}

void reverbDesign(double size, double decaySeconds, std::size_t lines, int channel, double sampleRate,
                  std::uint32_t* lengths, double* gains) noexcept {
    const double lowest = 0.020 * std::max(size, 0.01), highest = 0.055 * std::max(size, 0.01);
    const double stagger = 1.0 + 0.0123 * channel;
    std::uint64_t previous = 0;
    for (std::size_t i = 0; i < lines; ++i) {
        const double t = lines > 1 ? (static_cast<double>(i) + 0.5) / static_cast<double>(lines) : 0.5;
        const double seconds = lowest * std::pow(highest / lowest, t) * stagger;
        std::uint64_t frames = static_cast<std::uint64_t>(std::max(std::llround(seconds * sampleRate), 8ll));
        frames = nextPrime(std::max(frames, previous + 1));
        lengths[i] = static_cast<std::uint32_t>(frames);
        previous = frames;
        // −60 dB after `decaySeconds` of looping through this line.
        gains[i] = std::pow(10.0, -3.0 * static_cast<double>(frames) / (sampleRate * std::max(decaySeconds, 0.01)));
    }
}

std::size_t reverbStorageFloats(const std::uint32_t* lengths, std::size_t lines, std::size_t preDelayFrames, double sampleRate) noexcept {
    std::size_t total = 0;
    for (std::size_t i = 0; i < lines; ++i) total += lengths[i];
    std::size_t diffusers[4];
    diffuserLengths(7, sampleRate, diffusers);     // the longest set (channel 7, the last an input can have) bounds every channel
    for (std::size_t length : diffusers) total += length + 8;
    return total + preDelayFrames + 1;
}

void renderReverb(const std::uint32_t* const* lengths, const double* const* gains, float* const* storage, double* const* filters,
                  float* const* outputs, int channelCount, int firstChannel, const AudioInput& input,
                  const ReverbControls& controls, std::size_t frameOffset, std::size_t count) noexcept {
    const std::size_t lines = controls.lines;
    if (channelCount <= 0 || lines == 0) {
        return;
    }
    const bool early = controls.earlyLevel > 0 && controls.earlyFrames > 64;
    const bool modulates = controls.modulationDepth > 0 && controls.modulationMargin >= 9;
    const bool splits = std::fabs(controls.lowDecayScale - 1.0) > 1e-9 || std::fabs(controls.highDecayScale - 1.0) > 1e-9;
    const bool freezes = controls.freezeFrame >= 0;
    const std::size_t margin = modulates ? controls.modulationMargin : 0;
    const double normalize = 1.0 / std::sqrt(static_cast<double>(lines));
    // Output loudness is held constant: the response is scaled to about unit energy, so steady material comes out about
    // as loud as it went in whatever Decay, Size, line count or Damping say. In a diffuse network the response's energy
    // is about sampleRate × decay / (13.8 × total line length); short decays run a little above that, and Damping takes
    // energy out of the loop, so both are corrected for (fitted against measured responses). With a Low/High Decay split
    // the decay that counts is the average of the two bands, weighted by how much of the spectrum each one holds.
    std::vector<double> wetScale(static_cast<std::size_t>(channelCount));
    for (int c = 0; c < channelCount; ++c) {
        double total = 0;
        for (std::size_t i = 0; i < lines; ++i) total += lengths[c][i];
        const double decay = std::max(controls.decaySeconds, 0.01);
        double shaped = decay;
        if (splits) {
            const double lowShare = std::clamp(controls.crossoverHz / (0.5 * controls.sampleRate), 0.0, 1.0);
            shaped = std::max(decay * (lowShare * controls.lowDecayScale + (1.0 - lowShare) * controls.highDecayScale), 0.01);
        }
        const double predicted = controls.sampleRate * shaped / (13.8 * total) * (1.0 + 0.33 / shaped);
        // Damping loses broadband energy at −2·ln(1 − pole) per pass, and a loop makes sampleRate / meanLength passes a
        // second, against the 13.8 / decay per second Decay already takes (fitted against measured responses).
        const double pole = std::clamp(controls.damping, 0.0, 1.0) * 0.97;
        const double lossPerPass = -2.0 * std::log(1.0 - pole);
        const double passesPerSecond = controls.sampleRate * static_cast<double>(lines) / total;
        const double ratio = passesPerSecond * lossPerPass / (13.8 / shaped);
        wetScale[static_cast<std::size_t>(c)] = std::sqrt(1.0 / predicted) * std::sqrt(1.0 + 0.71 * std::pow(ratio, 0.58));
        if (modulates) {
            // Reading between frames darkens each pass a little, a constant 0.85 dB once the sweep is a frame or more deep.
            const double sweepFrames = controls.modulationDepth * 0.001 * controls.sampleRate;
            wetScale[static_cast<std::size_t>(c)] *= std::pow(10.0, 0.85 / 20.0 * std::min(1.0, sweepFrames));
        }
    }
    const double dampingPole = std::clamp(controls.damping, 0.0, 1.0) * 0.97;
    const double allpassGain = std::clamp(controls.diffusion, 0.0, 1.0) * 0.75;
    const bool fades = controls.tailFadeEnd > controls.tailFadeStart;
    const double crossoverPole = splits
        ? 1.0 - std::exp(-2.0 * pi * std::clamp(controls.crossoverHz, 20.0, 0.45 * controls.sampleRate) / controls.sampleRate) : 0.0;
    const std::size_t earlyLength = early ? controls.earlyFrames : 1;

    struct Channel {
        std::vector<float*> line;          // start of each line in storage
        std::vector<std::size_t> position; // current index in each line
        std::vector<std::size_t> ring;     // each line's ring length (its length, plus the margin when modulating)
        std::vector<double> inSign, outSign;
        std::vector<double> lowGain, highGain;                 // per-band loop gain (Low/High Decay)
        std::vector<double> rate, phase, depth, sweepA, sweepB;   // each line's LFO (Modulation)
        long long sweepBlock = -1;
        float* diffuser[4];
        std::size_t diffuserLength[4];
        std::size_t diffuserIndex[4];
        float* preDelay;
        std::size_t preDelayLength;
        std::size_t preDelayIndex;
        float* early = nullptr;
        std::size_t earlyReach[reverbEarlyTapCount];
        double earlyGain[reverbEarlyTapCount];
    };
    std::vector<Channel> channels(static_cast<std::size_t>(channelCount));
    for (int c = 0; c < channelCount; ++c) {
        Channel& channel = channels[static_cast<std::size_t>(c)];
        const std::uint64_t identity = static_cast<std::uint64_t>(firstChannel + c);
        float* cursor = storage[c];
        channel.line.resize(lines);
        channel.position.resize(lines);
        channel.ring.resize(lines);
        channel.inSign.resize(lines);
        channel.outSign.resize(lines);
        if (splits) {
            channel.lowGain.resize(lines);
            channel.highGain.resize(lines);
        }
        if (modulates) {
            channel.rate.resize(lines);
            channel.phase.resize(lines);
            channel.depth.resize(lines);
            channel.sweepA.assign(lines, 0.0);
            channel.sweepB.assign(lines, 0.0);
        }
        for (std::size_t i = 0; i < lines; ++i) {
            channel.line[i] = cursor;
            channel.ring[i] = lengths[c][i] + margin;
            cursor += channel.ring[i];
            channel.position[i] = frameOffset % lengths[c][i];
            channel.inSign[i] = (mixBits(2 * i + static_cast<std::size_t>(firstChannel + c) * 977) & 1) ? 1.0 : -1.0;
            channel.outSign[i] = (mixBits(7919 + 2 * i + static_cast<std::size_t>(firstChannel + c) * 613) & 1) ? 1.0 : -1.0;
            if (splits) {
                channel.lowGain[i] = std::pow(gains[c][i], 1.0 / std::max(controls.lowDecayScale, 0.01));
                channel.highGain[i] = std::pow(gains[c][i], 1.0 / std::max(controls.highDecayScale, 0.01));
            }
            if (modulates) {
                channel.rate[i] = 0.25 + 0.65 * unit(555 + 2 * i + identity * 1301);
                channel.phase[i] = 2.0 * pi * unit(9001 + 2 * i + identity * 1511);
                channel.depth[i] = std::min(controls.modulationDepth * 0.001 * controls.sampleRate, 0.25 * static_cast<double>(lengths[c][i]));
            }
        }
        diffuserLengths(firstChannel + c, controls.sampleRate, channel.diffuserLength);
        for (int d = 0; d < 4; ++d) {
            channel.diffuser[d] = cursor;
            cursor += channel.diffuserLength[d] + 8;
            channel.diffuserIndex[d] = frameOffset % channel.diffuserLength[d];
        }
        channel.preDelay = cursor;
        channel.preDelayLength = controls.preDelayFrames + 1;
        channel.preDelayIndex = frameOffset % channel.preDelayLength;
        cursor += channel.preDelayLength;
        if (early) {
            channel.early = cursor;
            reverbEarlyDesign(controls.size, firstChannel + c, controls.sampleRate, channel.earlyReach, channel.earlyGain);
        }
    }

    std::vector<double> delayed(lines), wet(static_cast<std::size_t>(channelCount));
    for (std::size_t n = 0; n < count; ++n) {
        const std::size_t frame = frameOffset + n;
        const double mix = std::clamp(static_cast<double>(controls.mix.valueAt(frame)), 0.0, 1.0);
        double fade = 1.0;
        if (fades && static_cast<double>(frame) >= controls.tailFadeStart) {
            const double t = (static_cast<double>(frame) - controls.tailFadeStart) / (controls.tailFadeEnd - controls.tailFadeStart);
            fade = t >= 1.0 ? 0.0 : 0.5 + 0.5 * std::cos(pi * t);
        }
        // Freeze: how far the loop has closed (0 = not at all). Input stops, gains go to 1, Damping is bypassed.
        double freezeAmount = 0.0;
        if (freezes && static_cast<double>(frame) >= controls.freezeFrame) {
            freezeAmount = controls.freezeFade > 0
                ? std::min((static_cast<double>(frame) - controls.freezeFrame) / controls.freezeFade, 1.0) : 1.0;
        }
        const double pole = freezeAmount > 0 ? dampingPole * (1.0 - freezeAmount) : dampingPole;
        double dry[8] = {0, 0, 0, 0, 0, 0, 0, 0};
        for (int c = 0; c < channelCount; ++c) {
            Channel& channel = channels[static_cast<std::size_t>(c)];
            const double source = input.spread(static_cast<std::size_t>(firstChannel + c), frame);
            dry[c] = source;
            // Pre-delay: write now, read `preDelayFrames` back.
            channel.preDelay[channel.preDelayIndex] = static_cast<float>(source);
            const std::size_t readIndex = (channel.preDelayIndex + channel.preDelayLength - controls.preDelayFrames) % channel.preDelayLength;
            double signal = channel.preDelay[readIndex];
            channel.preDelayIndex = (channel.preDelayIndex + 1) % channel.preDelayLength;
            if (freezeAmount > 0) {
                signal *= 1.0 - freezeAmount;
            }
            // Early reflections: taps of the signal as it is before the diffusers smear it.
            double reflections = 0.0;
            if (early) {
                channel.early[frame % earlyLength] = static_cast<float>(signal);
                for (std::size_t k = 0; k < reverbEarlyTapCount; ++k) {
                    reflections += channel.earlyGain[k] * channel.early[(frame + earlyLength - channel.earlyReach[k]) % earlyLength];
                }
            }
            // Series all-pass diffusion.
            for (int d = 0; d < 4; ++d) {
                const std::size_t index = channel.diffuserIndex[d];
                const double held = channel.diffuser[d][index];
                const double next = signal + allpassGain * held;
                channel.diffuser[d][index] = static_cast<float>(next);
                signal = held - allpassGain * next;
                channel.diffuserIndex[d] = (index + 1) % channel.diffuserLength[d];
            }
            // Each line's LFO is a sine sampled every 8 frames and interpolated between, from the absolute frame.
            double blend = 0.0;
            if (modulates) {
                const long long block = static_cast<long long>(frame >> 3);
                blend = static_cast<double>(frame & 7) * 0.125;
                if (channel.sweepBlock != block) {
                    channel.sweepBlock = block;
                    const double from = static_cast<double>(block * 8), to = static_cast<double>(block * 8 + 8);
                    for (std::size_t i = 0; i < lines; ++i) {
                        const double step = 2.0 * pi * channel.rate[i] / controls.sampleRate;
                        channel.sweepA[i] = std::sin(step * from + channel.phase[i]);
                        channel.sweepB[i] = std::sin(step * to + channel.phase[i]);
                    }
                }
            }
            // The network.
            double sum = 0, tapped = 0;
            for (std::size_t i = 0; i < lines; ++i) {
                double y;
                if (modulates) {
                    const double sweep = channel.sweepA[i] + (channel.sweepB[i] - channel.sweepA[i]) * blend;
                    // A frozen loop reads whole frames (the sweep fades out as it closes), so a lap never smooths it.
                    const double depth = freezeAmount > 0 ? channel.depth[i] * (1.0 - freezeAmount) : channel.depth[i];
                    const double reach = static_cast<double>(lengths[c][i]) + depth * sweep;
                    y = readRing(channel.line[i], channel.ring[i], static_cast<double>(frame) - reach);
                } else {
                    y = channel.line[i][channel.position[i]];
                }
                delayed[i] = y;
                tapped += channel.outSign[i] * y;
                double& state = filters[c][i];
                state = (1.0 - pole) * y + pole * state;
                if (std::fabs(state) < 1e-30) state = 0.0;
                if (splits) {
                    double& crossover = filters[c][lines + i];
                    crossover += crossoverPole * (state - crossover);
                    if (std::fabs(crossover) < 1e-30) crossover = 0.0;
                    double low = channel.lowGain[i], high = channel.highGain[i];
                    if (freezeAmount > 0) {
                        low += freezeAmount * (1.0 - low);
                        high += freezeAmount * (1.0 - high);
                    }
                    delayed[i] = low * crossover + high * (state - crossover);
                } else {
                    const double gain = freezeAmount > 0 ? gains[c][i] + freezeAmount * (1.0 - gains[c][i]) : gains[c][i];
                    delayed[i] = gain * state;
                }
                sum += delayed[i];
            }
            const double spread = 2.0 * sum / static_cast<double>(lines);
            for (std::size_t i = 0; i < lines; ++i) {
                double next = delayed[i] - spread + channel.inSign[i] * signal * normalize;
                if (!std::isfinite(next) || std::fabs(next) < 1e-30) next = std::isfinite(next) ? 0.0 : 0.0;
                if (modulates) {
                    channel.line[i][frame % channel.ring[i]] = static_cast<float>(next);
                } else {
                    channel.line[i][channel.position[i]] = static_cast<float>(next);
                    channel.position[i] = (channel.position[i] + 1) % lengths[c][i];
                }
            }
            wet[static_cast<std::size_t>(c)] = tapped * normalize * wetScale[static_cast<std::size_t>(c)];
            if (early) {
                wet[static_cast<std::size_t>(c)] += controls.earlyLevel * reflections;
            }
        }
        if (channelCount == 2 && controls.width != 1.0) {
            const double middle = 0.5 * (wet[0] + wet[1]), side = 0.5 * (wet[0] - wet[1]);
            wet[0] = middle + controls.width * side;
            wet[1] = middle - controls.width * side;
        }
        for (int c = 0; c < channelCount; ++c) {
            const double value = (dry[c] * (1.0 - mix) + wet[static_cast<std::size_t>(c)] * mix) * fade;
            outputs[c][n] = std::isfinite(value) ? static_cast<float>(value) : 0.0f;
        }
    }
}

} // namespace bake::dsp
