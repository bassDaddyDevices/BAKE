#pragma once

#include <cstddef>

#include "BakeDSP/Stft.h"

namespace bake::dsp {

enum class AverageMode : int { mean = 0, median = 1, geometric = 2 };

/// Ensemble Averager: the average of `count` values (reordered in place). Mean leaves out `trim`
/// (0…0.45) of the values at each end, rounded down; median is the middle value (the mean of the two
/// middle ones for an even count); geometric is exp of the mean log, so a 0 pulls it to 0.
double ensembleBin(double* values, std::size_t count, AverageMode mode, double trim) noexcept;

/// `out[i]` is the average of `magnitudes[clip * values + i]` over the `clips` clips. `scratch` holds
/// `clips` doubles.
void ensembleAverage(const float* magnitudes, std::size_t clips, std::size_t values, AverageMode mode,
                     double trim, double* scratch, float* out) noexcept;

/// The clip whose magnitudes are closest to `average` (least squared difference); its phase seeds
/// the resynthesis.
std::size_t ensembleTypical(const float* magnitudes, std::size_t clips, std::size_t values, const float* average) noexcept;

/// Doubles of scratch `ensembleGriffinLim` needs.
std::size_t ensembleScratchDoubles(const StftLayout& layout) noexcept;

/// Griffin-Lim. `spectrum` (`frameCount` frames, the layout's frame count for `signalFrames`) brings
/// the starting phase; its magnitudes become `magnitudes`, then `iterations` rounds of synthesis,
/// re-analysis and magnitude replacement refine the phase, and the result is synthesised into
/// `signal` (`signalFrames` floats). `rows` holds `stftRowFloats(layout, frameCount)` floats. With 0
/// iterations a spectrum that is already consistent comes back exactly.
void ensembleGriffinLim(const StftLayout& layout, const float* magnitudes, float* spectrum, std::size_t frameCount,
                        std::size_t signalFrames, std::size_t iterations, float* rows, float* signal,
                        double* scratch) noexcept;

} // namespace bake::dsp
