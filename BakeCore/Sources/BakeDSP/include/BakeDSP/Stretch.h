#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// Output frames per internal processing block. Blocks sit on absolute output positions,
/// so how the engine chunks a render never changes the result.
inline constexpr std::size_t stretchBlockFrames = 1024;

/// Opaque; owns a seeded Signalsmith stretcher. Create once per render step, destroy when done.
/// Unlike the plain-struct kernel states, the stretcher owns heap memory, so it never crosses
/// into Swift as a value.
struct StretchSession;

/// `inputs`/`outputs` are per-channel pointers into the render's buffer pool. The session copies
/// the pointer arrays (not the audio) and never frees them. Returns null for empty shapes.
StretchSession* createStretchSession(int channels, double sampleRate, int fftSize,
                                     const float* const* inputs, std::size_t inputFrames,
                                     float* const* outputs, std::size_t outputFrames) noexcept;

/// Produces output up to (at least) `untilFrame`. Pitch = `pitchSemitones` at each block's first
/// output frame + `cents`/100.
void renderStretch(StretchSession* session, std::size_t untilFrame,
                   const ParameterSignal& pitchSemitones, float cents) noexcept;

/// The same with Fine (cents) modulatable, read with Pitch at each block.
void renderStretch(StretchSession* session, std::size_t untilFrame,
                   const ParameterSignal& pitchSemitones, const ParameterSignal& cents) noexcept;

/// Formant preservation (Batch Conform): with `preserve`, a pitch shift keeps the spectral envelope, so voices
/// and instruments keep their size. Off by default, as the Stretch node has always been.
void setStretchFormants(StretchSession* session, bool preserve) noexcept;

void destroyStretchSession(StretchSession* session) noexcept;

} // namespace bake::dsp
