#include "BakeDSP/BeatRepeat.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {
namespace {

/// The shortest repeat: below this, accelerating ratchets hold as a buzz (3 kHz at 48 kHz).
constexpr double minimumRepeat = 16;

/// Uniform in [0, 1).
double nextRandom(std::uint32_t& state) noexcept {
    state = state * 1664525u + 1013904223u;
    return static_cast<double>(state >> 8) / 16777216.0;
}

double value(const ParameterSignal& signal, std::size_t frame) noexcept {
    return static_cast<double>(signal.valueAt(frame));
}

/// A note list entry by a (modulated) index, in quarter notes.
double noteAt(const double* notes, int count, const ParameterSignal& index, std::size_t frame, double fallback) noexcept {
    if (notes == nullptr || count < 1) {
        return fallback;
    }
    const int i = std::clamp(static_cast<int>(std::lround(value(index, frame))), 0, count - 1);
    return notes[i];
}

} // namespace

void renderBeatRepeat(BeatRepeatState* state, BeatRepeatMode mode, const BeatRepeatControls& controls,
                      const ControlInput& trigger, const float* input, std::size_t inputFrames, float* output,
                      std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || output == nullptr) {
        return;
    }
    const double rate = std::max(controls.sampleRate, 1.0);
    const float outsideGain = mode == BeatRepeatMode::insert ? 1.0f : 0.0f;
    // Unmodulated, the timer is exact (frame ÷ interval); modulated, it accumulates.
    const bool timerMoves = controls.tempo.modulation != nullptr || controls.interval.modulation != nullptr;
    auto& path = state->path;

    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const auto now = static_cast<double>(frame);
        if (!state->started) {
            state->started = true;
            state->random = controls.seed;
            path.position = now;
            path.oldPosition = now;
            path.gain = outsideGain;
            path.oldGain = outsideGain;
        }
        const double quarterFrames = 60 / std::clamp(value(controls.tempo, frame), 1.0, 1000.0) * rate;
        const double sixteenthFrames = quarterFrames / 4;
        const auto smoothFrames = [&](double repeatLength) {
            return std::min(std::max(value(controls.smooth, frame), 0.0) / 1000 * rate, repeatLength / 2);
        };
        // In Mix and Gate the live first repeat (Capture 0, no Pitch) is silent so the input isn't doubled.
        const auto audible = [&](int n, double pitch) {
            return mode == BeatRepeatMode::insert || n > 0 || state->capture != 0 || pitch != 0;
        };

        // The event ends, or moves on to its next repeat. Repeat values are read here.
        if (state->inEvent && now >= state->eventEnd) {
            state->inEvent = false;
            state->speed = 1;
            path.jump(now, smoothFrames(state->repeatLength), outsideGain);
        } else if (state->inEvent && now - state->repeatStart >= state->repeatLength) {
            const int n = ++state->repeat;
            const double pitch = value(controls.pitch, frame);
            state->repeatStart = now;
            state->repeatLength = std::max(state->repeatLength * std::max(value(controls.accelerate, frame), 0.01), minimumRepeat);
            state->repeatGain *= static_cast<float>(std::clamp(1 - value(controls.decay, frame), 0.0, 1.0));
            state->speed = std::exp2(std::clamp(pitch + n * value(controls.pitchDrift, frame), -96.0, 48.0) / 12);
            path.jump(state->sliceStart, smoothFrames(state->repeatLength), audible(n, pitch) ? state->repeatGain : 0.0f);
        }

        // A new event may start here: on a bang while Trigger is wired, else once per interval at the offset.
        bool candidate = false;
        if (trigger.isWired()) {
            const float level = trigger.valueAt(frame);
            candidate = level > 0.5f && state->previousTrigger <= 0.5f;
            state->previousTrigger = level;
        } else {
            const double intervalFrames = std::max(noteAt(controls.intervalQuarters, controls.intervalCount, controls.interval, frame, 4) * quarterFrames, 1.0);
            const double position = timerMoves ? state->intervalPosition : now / intervalFrames;
            const double offset = std::clamp(std::round(value(controls.offset, frame)), 0.0, 15.0) / 16;
            const auto index = static_cast<std::int64_t>(std::floor(position - offset));
            // Only forward: a modulated Offset sliding back never fires the same interval twice.
            candidate = index > state->lastInterval && position >= offset;
            state->lastInterval = std::max(state->lastInterval, index);
            state->intervalPosition += 1 / intervalFrames;
        }
        if (candidate) {
            // Both draws happen for every candidate, so Chance never shifts later events' variation.
            const double roll = nextRandom(state->random);
            const double variationRoll = nextRandom(state->random);
            if (roll < std::clamp(value(controls.chance, frame), 0.0, 1.0)) {
                const int levels = static_cast<int>(std::clamp(value(controls.variation, frame), 0.0, 1.0) * 3 + 0.5);
                const int halvings = std::min(static_cast<int>(variationRoll * (levels + 1)), levels);
                const double gridQuarters = noteAt(controls.gridQuarters, controls.gridCount, controls.grid, frame, 0.25);
                const double pitch = value(controls.pitch, frame);
                state->inEvent = true;
                state->eventEnd = now + std::max(std::round(value(controls.gate, frame)), 1.0) * sixteenthFrames;
                state->grid = std::max(gridQuarters * quarterFrames / std::exp2(halvings), 1.0);
                state->capture = std::round(value(controls.capture, frame));
                state->sliceStart = now + state->capture * state->grid;
                state->repeat = 0;
                state->repeatStart = now;
                state->repeatLength = std::max(state->grid, minimumRepeat);
                state->repeatGain = 1;
                state->speed = std::exp2(std::clamp(pitch, -96.0, 48.0) / 12);
                path.jump(state->sliceStart, smoothFrames(state->repeatLength), audible(0, pitch) ? 1.0f : 0.0f);
            }
        }

        const float wet = path.read(input, inputFrames);
        path.advance(state->inEvent ? state->speed : 1.0);
        const float dry = frame < inputFrames && std::isfinite(input[frame]) ? input[frame] : 0.0f;
        output[i] = mode == BeatRepeatMode::mix ? dry + wet : wet;
    }
}

} // namespace bake::dsp
