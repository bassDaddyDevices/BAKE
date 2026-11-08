#include "BakeDSP/Delay.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

/// The line at an absolute (possibly fractional) frame, 4-point Hermite. Frames not yet written read as 0.
inline float readLine(const float* line, std::size_t length, double position) noexcept {
    const double floor = std::floor(position);
    const double t = position - floor;
    const long long base = static_cast<long long>(floor);
    auto at = [&](long long frame) {
        long long index = frame % static_cast<long long>(length);
        if (index < 0) index += static_cast<long long>(length);
        return static_cast<double>(line[index]);
    };
    const double y0 = at(base - 1), y1 = at(base), y2 = at(base + 1), y3 = at(base + 2);
    const double c0 = y1;
    const double c1 = 0.5 * (y2 - y0);
    const double c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    const double c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    return static_cast<float>(((c3 * t + c2) * t + c1) * t + c0);
}

inline double flush(double value) noexcept {
    return std::fabs(value) < 1e-30 ? 0.0 : value;
}

/// The last `window` frames played backwards: two overlapping Hann grains (hop = window / 2) that sum to 1. A grain that
/// starts at frame `s` plays the line from `s - 1` downwards, so every read is of a frame already written. Frames before
/// the start of the file read as 0. Needs a line longer than twice the window.
inline double readReversed(const float* line, std::size_t length, std::size_t frame, long long window) noexcept {
    const long long hop = window / 2;
    const long long now = static_cast<long long>(frame);
    const long long k = now / hop;
    double sum = 0;
    for (int g = 0; g < 2; ++g) {
        const long long start = (k - g) * hop;
        const long long n = now - start;
        const long long source = start - 1 - n;
        if (source < 0 || n >= window || 2 * n + 1 >= static_cast<long long>(length) - 2) {
            continue;
        }
        const double weight = 0.5 - 0.5 * std::cos(2.0 * pi * static_cast<double>(n) / static_cast<double>(window));
        sum += weight * static_cast<double>(line[static_cast<std::size_t>(source) % length]);
    }
    return sum;
}

/// The echo `rate` times faster (or slower) than it was written: two read heads sweep a `window`-frame range of the
/// buffer, half a window apart, crossfading as each one wraps. The head's delay changes by `1 − rate` a frame, so what
/// it reads moves through the buffer at `rate`. Every phase comes from the absolute frame, so any chunking agrees.
inline double shiftRead(const float* buffer, std::size_t length, std::size_t frame, double window, double rate) noexcept {
    double phase = std::fmod(static_cast<double>(frame) * (1.0 - rate) / window, 1.0);
    if (phase < 0) {
        phase += 1.0;
    }
    double other = phase + 0.5;
    if (other >= 1.0) {
        other -= 1.0;
    }
    const double first = 0.5 - 0.5 * std::cos(2.0 * pi * phase);
    const double second = 0.5 - 0.5 * std::cos(2.0 * pi * other);
    const double now = static_cast<double>(frame);
    const double a = readLine(buffer, length, now - std::max(phase * window, 2.0));
    const double b = readLine(buffer, length, now - std::max(other * window, 2.0));
    return first * a + second * b;
}

inline double readWhole(const float* line, std::size_t length, long long frame) noexcept {
    return frame < 0 ? 0.0 : static_cast<double>(line[static_cast<std::size_t>(frame) % length]);
}

} // namespace

std::size_t delayLineFrames(double maxMilliseconds, double sampleRate) noexcept {
    return static_cast<std::size_t>(std::ceil(std::max(maxMilliseconds, 1.0) * 0.001 * sampleRate)) + 8;
}

void renderDelay(DelayState* states, float* const* lines, float* const* outputs, int channelCount, int firstChannel,
                 const AudioInput& input, const DelayControls& controls, std::size_t frameOffset, std::size_t count) noexcept {
    if (channelCount <= 0 || controls.lineFrames < 16) {
        return;
    }
    const std::size_t length = controls.lineFrames;
    const double longest = static_cast<double>(length) - 4.0;
    const bool crossing = channelCount == 2 && controls.pingPong > 0;
    const double cross = crossing ? std::clamp(controls.pingPong, 0.0, 1.0) : 0.0;
    const bool fades = controls.tailFadeEnd > controls.tailFadeStart;
    const bool shifts = controls.pitchSemitones != 0 && controls.shifterWindow >= 16 && controls.shifterLines != nullptr
        && controls.shifterFrames >= static_cast<std::size_t>(controls.shifterWindow) + 16;
    const double rate = shifts ? std::pow(2.0, controls.pitchSemitones / 12.0) : 1.0;
    const double shortening = shifts ? controls.shifterWindow * 0.5 : 0.0;
    const bool freezes = controls.freezeFrame >= 0;
    double frozenDelay = 0;
    if (freezes) {
        const std::size_t at = static_cast<std::size_t>(controls.freezeFrame);
        const double held = static_cast<double>(controls.time.valueAt(at)) * 0.001 * controls.sampleRate - shortening;
        frozenDelay = std::round(std::clamp(held, 2.0, longest));
    }
    double echoes[2] = {0, 0};
    double inputs[2] = {0, 0};
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double delay = shifts
            ? std::clamp(static_cast<double>(controls.time.valueAt(frame)) * 0.001 * controls.sampleRate - shortening, 2.0, longest)
            : std::clamp(static_cast<double>(controls.time.valueAt(frame)) * 0.001 * controls.sampleRate, 2.0, longest);
        const double feedback = std::clamp(static_cast<double>(controls.feedback.valueAt(frame)), 0.0, 0.995);
        const double cutoff = static_cast<double>(controls.damping.valueAt(frame));
        const double smoothing = cutoff >= 19'999.0 ? 1.0 : 1.0 - std::exp(-2.0 * pi * std::max(cutoff, 1.0) / controls.sampleRate);
        const double mix = std::clamp(static_cast<double>(controls.mix.valueAt(frame)), 0.0, 1.0);
        double fade = 1.0;
        if (fades && static_cast<double>(frame) >= controls.tailFadeStart) {
            const double t = (static_cast<double>(frame) - controls.tailFadeStart) / (controls.tailFadeEnd - controls.tailFadeStart);
            fade = t >= 1.0 ? 0.0 : 0.5 + 0.5 * std::cos(pi * t);
        }
        for (int c = 0; c < channelCount; ++c) {
            inputs[c] = input.spread(static_cast<std::size_t>(firstChannel + c), frame);
            echoes[c] = readLine(lines[c], length, static_cast<double>(frame) - delay);
            if (shifts) {
                float* buffer = controls.shifterLines[firstChannel + c];
                buffer[frame % controls.shifterFrames] = static_cast<float>(echoes[c]);
                echoes[c] = shiftRead(buffer, controls.shifterFrames, frame, controls.shifterWindow, rate);
            }
        }
        double freezeAmount = 0;
        if (freezes && static_cast<double>(frame) >= controls.freezeFrame) {
            freezeAmount = controls.freezeFade > 0
                ? std::min((static_cast<double>(frame) - controls.freezeFrame) / controls.freezeFade, 1.0) : 1.0;
        }
        for (int c = 0; c < channelCount; ++c) {
            const double other = crossing ? echoes[1 - c] : echoes[c];
            const double fed = (1.0 - cross) * echoes[c] + cross * other;
            DelayState& state = states[c];
            state.damping = flush(state.damping + smoothing * (fed - state.damping));
            double written = inputs[c] + feedback * state.damping;
            if (freezeAmount > 0) {
                // The loop as it was, whole frames behind, so a lap never smooths it. Ping-Pong keeps its routing.
                const long long behind = static_cast<long long>(frame) - static_cast<long long>(frozenDelay);
                const double own = readWhole(lines[c], length, behind);
                const double across = crossing ? readWhole(lines[1 - c], length, behind) : own;
                const double looped = (1.0 - cross) * own + cross * across;
                written = (1.0 - freezeAmount) * written + freezeAmount * looped;
            }
            lines[c][frame % length] = static_cast<float>(flush(written));
            double wet = echoes[c];
            for (std::size_t tap = 0; tap < controls.tapCount; ++tap) {
                if (controls.tapReversed != nullptr && controls.tapReversed[tap] != 0) {
                    long long window = 2 * static_cast<long long>(std::llround(controls.tapFrames[tap] * 0.5));
                    window = std::max<long long>(window, 4);
                    wet += static_cast<double>(controls.tapGains[tap]) * readReversed(lines[c], length, frame, window);
                    continue;
                }
                const double reach = std::clamp(controls.tapFrames[tap], 2.0, longest);
                wet += static_cast<double>(controls.tapGains[tap]) * readLine(lines[c], length, static_cast<double>(frame) - reach);
            }
            const double value = (inputs[c] * (1.0 - mix) + wet * mix) * fade;
            outputs[c][i] = std::isfinite(value) ? static_cast<float>(value) : 0.0f;
        }
    }
}

} // namespace bake::dsp
