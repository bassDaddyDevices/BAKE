#include "BakeDSP/Stretch.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "signalsmith-stretch/signalsmith-stretch.h"

namespace bake::dsp {
namespace {

/// Fixed so every render of the same plan is identical (the library randomises phases above 2×,
/// and its default constructor seeds from std::random_device).
constexpr long stretchSeed = 0x0BAE;

/// Whole-input view starting at `offset`; anything outside the input reads as silence.
struct PaddedInput {
    const std::vector<const float*>* channels;
    long long frames;
    long long offset;

    struct Channel {
        const float* data;
        long long frames;
        long long offset;
        float operator[](int index) const {
            const long long frame = offset + index;
            return (frame < 0 || frame >= frames) ? 0.0f : data[frame];
        }
    };

    Channel operator[](int channel) const { return {(*channels)[channel], frames, offset}; }
};

/// Output view starting at `offset`.
struct OffsetOutput {
    const std::vector<float*>* channels;
    std::size_t offset;
    float* operator[](int channel) const { return (*channels)[channel] + offset; }
};

} // namespace

struct StretchSession {
    signalsmith::stretch::SignalsmithStretch<float> stretcher{stretchSeed};
    std::vector<const float*> inputs;
    std::vector<float*> outputs;
    std::size_t inputFrames = 0;
    std::size_t outputFrames = 0;
    double playbackRate = 1;
    long long seekLength = 0;
    std::size_t mainOutputFrames = 0; ///< produced by process(); the rest comes from flush()
    std::size_t produced = 0;
    long long consumed = 0;
    bool flushed = false;
};

StretchSession* createStretchSession(int channels, double sampleRate, int fftSize,
                                     const float* const* inputs, std::size_t inputFrames,
                                     float* const* outputs, std::size_t outputFrames) noexcept {
    if (channels <= 0 || inputs == nullptr || outputs == nullptr || inputFrames == 0 || outputFrames == 0) {
        return nullptr;
    }
    (void)sampleRate; // configure() works in samples; kept for future time-based presets
    auto* session = new StretchSession();
    session->inputs.assign(inputs, inputs + channels);
    session->outputs.assign(outputs, outputs + channels);
    session->inputFrames = inputFrames;
    session->outputFrames = outputFrames;

    const int block = std::clamp(fftSize, 256, 16384);
    session->stretcher.configure(channels, block, block / 4);

    // Same sequence as the library's exact(): prime with outputSeek, process, then flush.
    session->playbackRate = static_cast<double>(inputFrames) / static_cast<double>(outputFrames);
    session->seekLength = session->stretcher.outputSeekLength(static_cast<float>(session->playbackRate));
    session->stretcher.outputSeek(PaddedInput{&session->inputs, static_cast<long long>(inputFrames), 0},
                                  static_cast<int>(session->seekLength));
    session->consumed = session->seekLength;
    const auto flushFrames = static_cast<long long>(static_cast<double>(session->seekLength) / session->playbackRate);
    session->mainOutputFrames = static_cast<std::size_t>(
        std::max<long long>(0, static_cast<long long>(outputFrames) - flushFrames));
    return session;
}

void setStretchFormants(StretchSession* session, bool preserve) noexcept {
    if (session != nullptr) session->stretcher.setFormantFactor(1.0f, preserve);
}

void renderStretch(StretchSession* session, std::size_t untilFrame,
                   const ParameterSignal& pitchSemitones, float cents) noexcept {
    ParameterSignal fixed;
    fixed.base = cents;
    renderStretch(session, untilFrame, pitchSemitones, fixed);
}

void renderStretch(StretchSession* session, std::size_t untilFrame,
                   const ParameterSignal& pitchSemitones, const ParameterSignal& cents) noexcept {
    if (session == nullptr) {
        return;
    }
    const std::size_t target = std::min(untilFrame, session->mainOutputFrames);
    while (session->produced < target) {
        const std::size_t start = session->produced;
        const std::size_t end = std::min(session->mainOutputFrames, (start / stretchBlockFrames + 1) * stretchBlockFrames);
        session->stretcher.setTransposeSemitones(pitchSemitones.valueAt(start) + cents.valueAt(start) / 100.0f);

        // Input consumed so far tracks output produced, proportionally.
        const long long remainingInput = static_cast<long long>(session->inputFrames) - session->seekLength;
        const long long inputEnd = session->seekLength + std::llround(
            static_cast<double>(remainingInput) * static_cast<double>(end) / static_cast<double>(session->mainOutputFrames));
        session->stretcher.process(
            PaddedInput{&session->inputs, static_cast<long long>(session->inputFrames), session->consumed},
            static_cast<int>(inputEnd - session->consumed),
            OffsetOutput{&session->outputs, start}, static_cast<int>(end - start));
        session->consumed = inputEnd;
        session->produced = end;
    }
    if (!session->flushed && untilFrame >= session->outputFrames) {
        // The tail uses the last block's pitch, as the stretcher holds it.
        session->stretcher.flush(OffsetOutput{&session->outputs, session->mainOutputFrames},
                                 static_cast<int>(session->outputFrames - session->mainOutputFrames),
                                 static_cast<float>(session->playbackRate));
        session->flushed = true;
        session->produced = session->outputFrames;
    }
}

void destroyStretchSession(StretchSession* session) noexcept {
    delete session;
}

} // namespace bake::dsp
