#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// Fixed for a render, except the four signals.
struct DelayControls {
    ParameterSignal time;       ///< ms, the main tap and the feedback loop
    ParameterSignal feedback;   ///< 0…1, how much of the damped echo goes back in
    ParameterSignal damping;    ///< Hz, a one-pole low-pass in the loop (at 20 kHz or more the loop is untouched)
    ParameterSignal mix;        ///< 0 = dry, 1 = echoes only
    double pingPong = 0;        ///< 0…1, how much of the feedback crosses to the other channel (stereo only)
    const double* tapFrames = nullptr;   ///< extra reads of the line, in frames behind the write head
    const float* tapGains = nullptr;     ///< linear level of each tap
    std::size_t tapCount = 0;
    double sampleRate = 48000;
    std::size_t lineFrames = 0;          ///< length of each channel's circular line, longer than every time and tap
    /// Taps marked 1 here play the last `tapFrames` of the line backwards (null = none do). A reversed tap is wet only.
    const unsigned char* tapReversed = nullptr;
    /// Pitch per repeat: every repeat is shifted this many semitones further than the one before (0 = off). The shifter
    /// reads the echo through a short two-tap crossfade of `shifterWindow` frames, so the loop is shortened by half a
    /// window to keep Time honest. `shifterLines` is one buffer of `shifterFrames` per channel, indexed by absolute channel.
    double pitchSemitones = 0;
    double shifterWindow = 0;
    std::size_t shifterFrames = 0;
    float* const* shifterLines = nullptr;
    /// From this absolute frame the line takes no more input and loops its contents at unity (below 0 = never). The loop
    /// is the delay as it was at that frame, rounded to whole frames so laps never smear; it takes over over `freezeFade`.
    double freezeFrame = -1;
    double freezeFade = 0;
    /// The wet signal fades out over `[tailFadeStart, tailFadeEnd)` so the tail never ends on a click (0, 0 = no fade).
    double tailFadeStart = 0;
    double tailFadeEnd = 0;
};

/// The state a channel carries between chunks besides its line: the damping filter's memory.
struct DelayState {
    double damping = 0;
};

/// Renders `channelCount` coupled channels (1, or 2 with ping-pong) for frames `[frameOffset, frameOffset + count)`.
/// `states`, `lines` and `outputs` point at the first of those channels' entries; `firstChannel` is the input channel
/// the first of them reads. Every line is indexed by absolute frame, so any chunking gives the same bits.
void renderDelay(DelayState* states, float* const* lines, float* const* outputs, int channelCount, int firstChannel,
                 const AudioInput& input, const DelayControls& controls, std::size_t frameOffset, std::size_t count) noexcept;

/// The most frames a delay of `maxMilliseconds` can reach, as a line length.
std::size_t delayLineFrames(double maxMilliseconds, double sampleRate) noexcept;

} // namespace bake::dsp
