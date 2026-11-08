#pragma once

#include <cstddef>
#include <cstdint>

namespace bake::dsp {

/// Summaries of a finished signal for the cards: what a node produced, drawn after a bake.
/// Both functions read whole channels, so nothing here depends on how the render was chunked.

/// Per bucket across the signal: the lowest and highest sample of any channel, and the RMS of all
/// channels together. `buckets` must not exceed `frames`; non-finite samples count as 0.
void summarizeEnvelope(const float* const* channels, std::size_t channelCount, std::size_t frames, std::size_t buckets,
                       float* minimums, float* maximums, float* rms) noexcept;

inline constexpr std::size_t spectrogramWindow = 4096;
/// Doubles `analyzeSpectrogram` needs as scratch.
inline constexpr std::size_t spectrogramScratchDoubles = 5 * spectrogramWindow;
/// Doubles `analyzeSpectrogram` needs as scratch (the same number, as a function Swift can call).
inline std::size_t spectrogramScratchCount() noexcept { return spectrogramScratchDoubles; }
inline constexpr double spectrogramLowestHz = 30.0;
inline constexpr double spectrogramFloorDecibels = -90.0;

/// A `columns` x `rows` spectrogram of the channels' average, written row by row with row 0 the
/// lowest band. Rows are log-spaced from 30 Hz to 20 kHz (or 0.45 x the sample rate); each column
/// is a Hann-windowed 4096-point FFT centred on that column's place in the signal. A value is
/// the band's loudest bin, 0 at -90 dBFS or below and 255 at 0 dBFS (a full-scale sine).
void analyzeSpectrogram(const float* const* channels, std::size_t channelCount, std::size_t frames, double sampleRate,
                        std::size_t columns, std::size_t rows, std::uint8_t* output, double* scratch) noexcept;

} // namespace bake::dsp
