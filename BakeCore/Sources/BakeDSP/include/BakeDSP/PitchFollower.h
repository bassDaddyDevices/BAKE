#pragma once

#include <cstddef>

#include "BakeDSP/AudioInput.h"
#include "BakeDSP/Modulation.h"

namespace bake::dsp {

// The Pitch Follower: audio in, pitch and confidence out as control signals. The input is complete
// before the node runs, so each estimate's window is centred on its own frame and the track has no
// lag. Estimates are made every few milliseconds, just ahead of each chunk, into a buffer the
// caller keeps; they depend only on the input and the parameters at their own frames, so any
// chunking gives the same bits.

/// How the pitch reaches the output (the catalog's `output` options, in order).
enum class PitchFollowerOutput : int {
    log = 0,     ///< 0…1 across Min…Max in octaves
    linear = 1,  ///< 0…1 across Min…Max in Hz
    note = 2,    ///< MIDI note ÷ 127 (A4 = 69/127)
};

/// What an estimate without a clear pitch outputs (the catalog's `unvoiced` options, in order).
enum class PitchFollowerUnvoiced : int { hold = 0, fallToMin = 1, zero = 2 };

/// How estimates are cleaned up (the catalog's `smoothing` options, in order).
enum class PitchFollowerSmoothing : int {
    median = 0, ///< the median of the neighbouring estimates
    path = 1,   ///< the best path through several candidates per estimate over the whole file (no octave jumps)
};

/// How Glide is applied (the catalog's `glidePhase` options, in order).
enum class PitchFollowerGlidePhase : int {
    causal = 0,    ///< a one-pole that trails the pitch
    zeroPhase = 1, ///< the same one-pole forward then backward over the whole file: smooth, with no lag
};

/// The lowest Min Freq the catalog allows; it sizes the analysis window.
constexpr double pitchFollowerLowestFrequency = 30.0;

struct PitchFollowerControls {
    ParameterSignal minFreq;    ///< Hz, 30–2000
    ParameterSignal maxFreq;    ///< Hz, 100–4000; taken as at least Min × 1.01
    ParameterSignal glide;      ///< ms, 0–500: a time constant on the output
    ParameterSignal threshold;  ///< 0–1: the confidence an estimate needs to count as a note
    ParameterSignal output;     ///< option index of PitchFollowerOutput
    ParameterSignal unvoiced;   ///< option index of PitchFollowerUnvoiced
    PitchFollowerOutput fixedOutput = PitchFollowerOutput::log;
    PitchFollowerUnvoiced fixedUnvoiced = PitchFollowerUnvoiced::hold;
    double sampleRate = 48000;
    PitchFollowerSmoothing smoothing = PitchFollowerSmoothing::median;
    PitchFollowerGlidePhase glidePhase = PitchFollowerGlidePhase::causal;
    double hopMilliseconds = 5.0; ///< time between estimates
    /// Zero-phase Glide: one float per frame of the whole input, borrowed from the caller (null otherwise).
    float* glideBuffer = nullptr;
    std::size_t glideFrames = 0;
};

/// Carried between chunks, with the caller's estimates and scratch.
struct PitchFollowerState {
    std::size_t analysed = 0;   ///< estimates with a raw pitch and confidence
    std::size_t resolved = 0;   ///< estimates with their median and held pitch too
    double level = 0;           ///< the glided output
    bool started = false;
    bool twiddlesReady = false;
    float lastGlide = -1;
    double glideCoefficient = 0;
    bool pathResolved = false;  ///< the whole-file path has been chosen
    bool glideBuilt = false;    ///< zero-phase Glide has filled its buffer
};

/// Frames between estimates (about 5 ms); estimate i is centred on frame i × hop.
std::size_t pitchFollowerHop(double sampleRate) noexcept;
/// The same with the estimates `hopMilliseconds` apart.
std::size_t pitchFollowerHop(double sampleRate, double hopMilliseconds) noexcept;
/// Estimates needed for an input of `frames` (one past the last frame's, for interpolation).
std::size_t pitchFollowerEstimateCount(std::size_t frames, double sampleRate) noexcept;
std::size_t pitchFollowerEstimateCount(std::size_t frames, double sampleRate, double hopMilliseconds) noexcept;
/// Floats per estimate in the caller's `estimates` buffer.
std::size_t pitchFollowerFloatsPerEstimate() noexcept;
/// Doubles of scratch the analysis needs; keep it with the state between chunks.
std::size_t pitchFollowerScratchDoubles(double sampleRate) noexcept;

/// Fills a scratch buffer's twiddle tables. Every scratch handed to `pitchFollowerAnalyse` needs this once.
void pitchFollowerPrepareScratch(double sampleRate, double* scratch) noexcept;

/// The end (exclusive) of the estimates `renderPitchFollower` needs analysed before it can write
/// frames `frameOffset …`, given what `state` already holds. The whole-file path needs all of them.
std::size_t pitchFollowerEstimatesNeeded(const PitchFollowerState& state, const PitchFollowerControls& controls,
                                         std::size_t estimateCount, std::size_t frameOffset, std::size_t count) noexcept;

/// Analyses estimates `first …< last` into `estimates`. They depend only on the input and the parameters at
/// their own frames, so any split of the range across threads (one prepared scratch each) gives the same bits. The
/// caller then sets `state.analysed` to `last` (the ranges handed out must run consecutively from `state.analysed`).
void pitchFollowerAnalyse(const PitchFollowerControls& controls, const AudioInput& input, float* estimates,
                          std::size_t first, std::size_t last, double* scratch) noexcept;

/// Pitch and confidence for frames `frameOffset`…`frameOffset + count − 1`. `input` is the whole
/// input; `pitch` and `confidence` are this chunk's outputs, either of which may be null.
void renderPitchFollower(PitchFollowerState* state, const PitchFollowerControls& controls, const AudioInput& input,
                         float* estimates, std::size_t estimateCount, double* scratch, float* pitch,
                         float* confidence, std::size_t frameOffset, std::size_t count) noexcept;

} // namespace bake::dsp
