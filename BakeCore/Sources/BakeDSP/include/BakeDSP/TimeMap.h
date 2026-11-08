#pragma once

#include <cstddef>

namespace bake::dsp {

// The time-map engine: a node that plays its input from somewhere else in time (Half Time, and
// later Beat Repeat, Looper, Stutter) holds a play position into the whole input channel and reads
// it here. The step renders after its input is complete, so any position, even ahead, is readable.

/// The input at a fractional frame, 4-point Hermite. Positions outside 0…frames−1 read 0;
/// non-finite samples read 0.
float timeMapRead(const float* input, std::size_t frames, double position) noexcept;

/// A play position that can jump. After a jump the old path keeps playing and fades out
/// equal-power while the new one fades in, so a jump never clicks.
struct TimeMapPath {
    double position = 0;
    double oldPosition = 0;
    double fadeDone = 0;
    double fadeFrames = 0;   ///< 0 while no fade runs
    /// Each path's level, so a jump that also changes level (a decaying repeat) fades it too.
    float gain = 1;
    float oldGain = 1;

    /// Moves to `target`, fading over `smoothFrames` (under 1 = cut). Jumping in place does nothing.
    void jump(double target, double smoothFrames) noexcept { jump(target, smoothFrames, gain); }
    /// The same, arriving at level `newGain`.
    void jump(double target, double smoothFrames, float newGain) noexcept;
    /// The output at the current position, stepping any fade one frame.
    float read(const float* input, std::size_t frames) noexcept;
    void advance(double speed) noexcept {
        position += speed;
        oldPosition += speed;
    }
    /// The fading-out path keeps its own speed (a Looper's reversed pass fading into a forward one).
    void advance(double speed, double oldSpeed) noexcept {
        position += speed;
        oldPosition += oldSpeed;
    }
};

/// One grain: a Hann-windowed read at speed 1 from `start`.
struct TimeMapGrain {
    bool active = false;
    double start = 0;
    int age = 0;
    int length = 0;   ///< frames; set at launch, so grains of different lengths can overlap
};

/// Grains of `grainFrames`, launched every half grain so their Hann windows sum to 1. Each new
/// grain is nudged (WSOLA) to line up with the waveform the previous grain is about to play, which
/// keeps the pitch when the position moves at any speed.
struct TimeMapGrains {
    /// Enough for grains of changing length to overlap (a long one under several short ones).
    static constexpr int voices = 16;
    TimeMapGrain grains[voices];
    bool hasLast = false;
    double lastStart = 0;

    /// Starts a grain near `start`. `grainFrames` must be even and at least 2.
    void launch(const float* input, std::size_t frames, double start, int grainFrames) noexcept;
    /// The sum of the active grains this frame, ageing each one frame. With `normalize` (grains of
    /// changing length, whose windows no longer sum to 1) the sum is divided by the windows' total.
    float read(const float* input, std::size_t frames, int grainFrames, bool normalize = false) noexcept;
};

} // namespace bake::dsp
