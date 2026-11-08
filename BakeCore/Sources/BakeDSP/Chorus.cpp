#include "BakeDSP/Chorus.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

std::size_t wrapIndex(long long index, std::size_t size) noexcept {
    const long long modulus = static_cast<long long>(size);
    const long long remainder = index % modulus;
    return static_cast<std::size_t>(remainder < 0 ? remainder + modulus : remainder);
}

float readLinear(const float* line, std::size_t size, double position) noexcept {
    const long long base = static_cast<long long>(std::floor(position));
    const double fraction = position - static_cast<double>(base);
    const double a = line[wrapIndex(base, size)];
    const double b = line[wrapIndex(base + 1, size)];
    return static_cast<float>(a + (b - a) * fraction);
}

} // namespace

void renderChorus(ChorusState* state, const ParameterSignal& detune, const ParameterSignal& spread,
                  const ParameterSignal& mix, int voices, double driftRate, double panSpread,
                  double sampleRate, double channelPhase,
                  float* delayLine, std::size_t delayLineFrames,
                  const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    renderChorus(state, detune, spread, mix, voices, driftRate, panSpread, ParameterSignal(), ParameterSignal(),
                 sampleRate, channelPhase, delayLine, delayLineFrames, input, output, frameOffset, count);
}

void renderChorus(ChorusState* state, const ParameterSignal& detune, const ParameterSignal& spread,
                  const ParameterSignal& mix, int voices, double fixedDriftRate, double fixedPanSpread,
                  const ParameterSignal& driftSignal, const ParameterSignal& panSignal,
                  double sampleRate, double channelPhase,
                  float* delayLine, std::size_t delayLineFrames,
                  const float* input, float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || delayLine == nullptr || input == nullptr || output == nullptr || delayLineFrames < 8 || !(sampleRate > 0)) {
        return;
    }
    const int voiceCount = std::clamp(voices, 2, maxChorusVoices);
    constexpr double pi = 3.14159265358979323846;
    constexpr double twoPi = 2.0 * pi;
    const double maximumDelaySamples = static_cast<double>(delayLineFrames - 3);
    const double maxDetune = std::clamp(static_cast<double>(detune.maximum), 0.0, 30.0);

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double dry = std::isfinite(input[i]) ? input[i] : 0.0;
        const double driftRate = modulatedOr(driftSignal, frame, fixedDriftRate);
        const double panSpread = modulatedOr(panSignal, frame, fixedPanSpread);
        // `channelPhase` is π × Pan Spread on the right channel; a modulated Pan Spread moves it too.
        const double channelOffset = panSignal.modulation == nullptr || channelPhase == 0 ? channelPhase : pi * panSpread;
        const double cents = std::clamp(static_cast<double>(detune.valueAt(frame)), 0.0, maxDetune);
        const double spreadAmount = std::clamp(static_cast<double>(spread.valueAt(frame)), 0.0, 1.0);
        const double writeIndex = state->writePosition;
        delayLine[static_cast<std::size_t>(writeIndex)] = static_cast<float>(dry);

        double wet = 0;
        const double wetScale = 1.0 / std::sqrt(static_cast<double>(voiceCount));
        for (int voice = 0; voice < voiceCount; ++voice) {
            const double voicePosition = static_cast<double>(voice) / voiceCount;
            const double phaseOffset = twoPi * voicePosition + channelOffset * std::clamp(panSpread, 0.0, 1.0);
            state->phases[voice] += twoPi * std::clamp(driftRate, 0.01, 10.0) / sampleRate;
            if (state->phases[voice] >= twoPi) {
                state->phases[voice] -= twoPi;
            }
            const double wobble = std::sin(state->phases[voice] + phaseOffset);
            // Pitch comes from how fast the delay moves: a sine of depth D samples at rate f gives a
            // peak pitch ratio of D·2πf/sampleRate, so D is chosen to make that Detune cents.
            const double rate = std::clamp(driftRate, 0.01, 10.0);
            const double depth = (std::pow(2.0, cents / 1'200.0) - 1.0) * sampleRate / (twoPi * rate);
            const double centerDelay = 0.012 * sampleRate;
            // Spread fans the voices' resting delays across ±6 ms; Pan Spread (via channelPhase) offsets
            // the right channel's wobble.
            const double offset = centerDelay * 0.5 * spreadAmount * (2.0 * voicePosition - 1.0);
            const double voiceDelay = centerDelay + offset + depth * wobble;
            const double clampedDelay = std::clamp(voiceDelay, 1.0, maximumDelaySamples);
            const double readPosition = writeIndex - clampedDelay;
            wet += readLinear(delayLine, delayLineFrames, readPosition) * wetScale;
        }
        const double blend = std::clamp(static_cast<double>(mix.valueAt(frame)), 0.0, 1.0);
        const double result = dry + (wet - dry) * blend;
        output[i] = std::isfinite(result) ? static_cast<float>(result) : 0.0f;
        state->writePosition += 1.0;
        if (state->writePosition >= delayLineFrames) {
            state->writePosition = 0;
        }
    }
}

// MARK: Swarm

namespace {

std::uint32_t mixBits(std::uint32_t value) noexcept {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    value ^= value >> 16;
    return value;
}

/// Uniform in [0, 1) from a voice and a set (0 is shared by every channel).
double hashed(std::size_t voice, std::size_t set) noexcept {
    const auto key = static_cast<std::uint32_t>(voice) * 0x9e3779b1U ^ (static_cast<std::uint32_t>(set) + 1U) * 0x85ebca6bU ^ 0x5bd1e995U;
    return static_cast<double>(mixBits(key) >> 8) / 16'777'216.0;
}

double wholeSampleAt(const float* data, std::size_t frames, long long index) noexcept {
    if (index < 0 || index >= static_cast<long long>(frames)) {
        return 0.0;
    }
    const double value = data[index];
    return std::isfinite(value) ? value : 0.0;
}

} // namespace

std::size_t chorusSwarmTableDoubles(int voices) noexcept {
    return 4 * static_cast<std::size_t>(std::clamp(voices, 1, maxChorusSwarmVoices));
}

void buildChorusSwarmTable(int voices, double reachMs, double sampleRate, std::size_t channel, double* table) noexcept {
    if (table == nullptr || !(sampleRate > 0)) {
        return;
    }
    const auto count = static_cast<std::size_t>(std::clamp(voices, 1, maxChorusSwarmVoices));
    constexpr double twoPi = 2.0 * 3.14159265358979323846;
    const double centerDelay = 0.012 * sampleRate;
    const double reach = std::clamp(reachMs, 0.0, maxChorusReachMs) * sampleRate / 1'000.0;
    for (std::size_t voice = 0; voice < count; ++voice) {
        const double position = static_cast<double>(voice) / static_cast<double>(count);
        table[voice] = centerDelay * 0.5 * (2.0 * position - 1.0);
        table[count + voice] = reach * (2.0 * hashed(voice, 0) - 1.0);
        table[2 * count + voice] = reach * (2.0 * hashed(voice, channel) - 1.0);
        table[3 * count + voice] = twoPi * position;
    }
}

void buildChorusDrift(const ParameterSignal& driftSignal, double fixedDriftRate, double sampleRate,
                      std::size_t frames, double* phase) noexcept {
    if (phase == nullptr || !(sampleRate > 0)) {
        return;
    }
    constexpr double twoPi = 2.0 * 3.14159265358979323846;
    double accumulated = 0.0;
    for (std::size_t frame = 0; frame < frames; ++frame) {
        accumulated += twoPi * std::clamp(modulatedOr(driftSignal, frame, fixedDriftRate), 0.01, 10.0) / sampleRate;
        if (accumulated >= twoPi) {
            accumulated -= twoPi;
        }
        phase[frame] = accumulated;
    }
}

void renderChorusSwarm(const ChorusSwarm& controls, bool rightChannel, const double* table, const double* driftPhase,
                       const float* input, std::size_t frames,
                       float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (table == nullptr || driftPhase == nullptr || input == nullptr || output == nullptr || frames == 0
        || !(controls.sampleRate > 0)) {
        return;
    }
    constexpr double pi = 3.14159265358979323846;
    constexpr double twoPi = 2.0 * pi;
    const double sampleRate = controls.sampleRate;
    const auto voices = static_cast<std::size_t>(std::clamp(controls.voices, 1, maxChorusSwarmVoices));
    const double* fan = table;
    const double* shared = table + voices;
    const double* own = table + 2 * voices;
    const double* basePhase = table + 3 * voices;
    const double wetScale = 1.0 / std::sqrt(static_cast<double>(voices));
    const double centerDelay = 0.012 * sampleRate;
    const double maxDetune = std::clamp(static_cast<double>(controls.detune.maximum), 0.0, 30.0);

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const double dry = wholeSampleAt(input, frames, static_cast<long long>(frame));
        const double rate = std::clamp(modulatedOr(controls.driftSignal, frame, controls.driftRate), 0.01, 10.0);
        const double pan = modulatedOr(controls.panSignal, frame, controls.panSpread);
        const double panAmount = std::clamp(pan, 0.0, 1.0);
        // The right channel's wobble is offset by π × Pan Spread, scaled by Pan Spread again, as in the classic chorus.
        const double channelOffset = rightChannel ? pi * pan * panAmount : 0.0;
        const double cents = std::clamp(static_cast<double>(controls.detune.valueAt(frame)), 0.0, maxDetune);
        const double spreadAmount = std::clamp(static_cast<double>(controls.spread.valueAt(frame)), 0.0, 1.0);
        // Pitch comes from how fast the delay moves; this depth makes the wobble's peak pitch `cents`.
        const double depth = (std::pow(2.0, cents / 1'200.0) - 1.0) * sampleRate / (twoPi * rate);
        const double phase = driftPhase[frame < frames ? frame : frames - 1];

        double wet = 0.0;
        for (std::size_t voice = 0; voice < voices; ++voice) {
            const double reach = shared[voice] + (own[voice] - shared[voice]) * panAmount;
            const double wobble = std::sin(phase + basePhase[voice] + channelOffset);
            const double delay = centerDelay + spreadAmount * (fan[voice] + reach) + depth * wobble;
            const double position = static_cast<double>(frame) - delay;
            const long long base = static_cast<long long>(std::floor(position));
            const double fraction = position - static_cast<double>(base);
            const double a = wholeSampleAt(input, frames, base);
            const double b = wholeSampleAt(input, frames, base + 1);
            wet += (a + (b - a) * fraction) * wetScale;
        }
        const double blend = std::clamp(static_cast<double>(controls.mix.valueAt(frame)), 0.0, 1.0);
        const double result = dry + (wet - dry) * blend;
        output[i] = std::isfinite(result) ? static_cast<float>(result) : 0.0f;
    }
}

} // namespace bake::dsp
