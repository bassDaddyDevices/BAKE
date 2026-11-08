#include "BakeDSP/TemporalShatter.h"

#include <algorithm>
#include <cmath>

namespace bake::dsp {

namespace {

constexpr double hopSeconds = 0.005;
constexpr double minimumGapSeconds = 0.03;
constexpr double floorEnergyPerFrame = 1e-6; // about −60 dBFS
constexpr double crossfadeSeconds = 0.002;   // tape → grains after an anchor ends

std::size_t hopFrames(double rate) noexcept { return std::max<std::size_t>(1, static_cast<std::size_t>(std::lround(hopSeconds * rate))); }
std::size_t gapFrames(double rate) noexcept { return std::max<std::size_t>(1, static_cast<std::size_t>(std::lround(minimumGapSeconds * rate))); }

} // namespace

std::size_t temporalShatterMaxOnsets(std::size_t inputFrames, double sampleRate) noexcept {
    return inputFrames / gapFrames(sampleRate) + 2;
}

std::size_t temporalShatterMaxSegments(std::size_t inputFrames, double sampleRate) noexcept {
    return 2 * temporalShatterMaxOnsets(inputFrames, sampleRate) + 1;
}

std::size_t analyzeTemporalShatter(const TemporalShatterControls& controls, const AudioInput& input,
                                   std::size_t outputFrames, std::size_t* onsets,
                                   TemporalShatterSegment* segments) noexcept {
    const std::size_t frames = input.frames;
    const double rate = controls.sampleRate;
    if (onsets == nullptr || segments == nullptr) {
        return 0;
    }
    if (frames == 0 || outputFrames == 0) {
        segments[0] = TemporalShatterSegment{0, 0, 1, false};
        return 1;
    }
    // 1. Onsets on the mono sum.
    const std::size_t hop = hopFrames(rate);
    const std::size_t gap = gapFrames(rate);
    const double channels = static_cast<double>(std::max<std::size_t>(input.channelCount, 1));
    const std::size_t maxOnsets = temporalShatterMaxOnsets(frames, rate);
    std::size_t onsetCount = 0;
    double previous = 0;
    bool any = false;
    std::size_t last = 0;
    for (std::size_t start = 0; start < frames; start += hop) {
        double energy = 0;
        const std::size_t end = std::min(start + hop, frames);
        for (std::size_t n = start; n < end; ++n) {
            double mono = 0;
            for (std::size_t c = 0; c < input.channelCount; ++c) {
                mono += input.sample(c, n);
            }
            mono /= channels;
            energy += mono * mono;
        }
        const double rise = std::pow(10.0, (12 - 9 * static_cast<double>(controls.sensitivity.valueAt(start))) / 10);
        const bool loud = energy / static_cast<double>(end - start) > floorEnergyPerFrame;
        if (loud && energy >= std::max(previous, 1e-10) * rise && (!any || start - last >= gap) && onsetCount < maxOnsets) {
            onsets[onsetCount++] = start;
            last = start;
            any = true;
        }
        previous = energy;
    }

    // 2. Anchors: each onset's first Attack ms, clipped to the input and the next onset.
    auto anchorEnd = [&](std::size_t i) {
        const auto attack = static_cast<std::size_t>(std::max(1.0, std::round(controls.attack.valueAt(onsets[i]) * 0.001 * rate)));
        std::size_t end = std::min(onsets[i] + attack, frames);
        if (i + 1 < onsetCount) {
            end = std::min(end, onsets[i + 1]);
        }
        return end;
    };
    std::size_t anchored = 0;
    for (std::size_t i = 0; i < onsetCount; ++i) {
        anchored += anchorEnd(i) - onsets[i];
    }
    const double total = static_cast<double>(outputFrames);
    if (onsetCount == 0 || anchored >= frames || static_cast<double>(anchored) >= total) {
        // Nothing to anchor (or nothing left to stretch): one uniform stretch.
        segments[0] = TemporalShatterSegment{0, 0, static_cast<double>(frames) / total, false};
        return 1;
    }

    // 3. The map. Tails share the output not taken by anchors; anchors start on whole output frames,
    // and each tail runs at the speed that lands it exactly on the next anchor.
    const double factor = (total - static_cast<double>(anchored)) / static_cast<double>(frames - anchored);
    std::size_t count = 0;
    double idealOutput = 0;  // where the output would be without rounding
    double output = 0;       // where the previous piece ended
    std::size_t source = 0;
    for (std::size_t i = 0; i < onsetCount; ++i) {
        const std::size_t onset = onsets[i];
        if (onset > source) {
            idealOutput += static_cast<double>(onset - source) * factor;
            const double anchorStart = std::round(idealOutput);
            if (anchorStart > output) {
                segments[count++] = TemporalShatterSegment{output, static_cast<double>(source),
                                                           static_cast<double>(onset - source) / (anchorStart - output), false};
            }
            output = anchorStart;
            source = onset;
        }
        const std::size_t end = anchorEnd(i);
        segments[count++] = TemporalShatterSegment{output, static_cast<double>(onset), 1, true};
        output += static_cast<double>(end - onset);
        idealOutput = output;
        source = end;
    }
    if (source < frames) {
        const double remaining = std::max(total - output, 1.0);
        segments[count++] = TemporalShatterSegment{output, static_cast<double>(source),
                                                   static_cast<double>(frames - source) / remaining, false};
    }
    return count;
}

void renderTemporalShatter(TemporalShatterState* state, const TemporalShatterControls& controls,
                           const TemporalShatterSegment* segments, std::size_t segmentCount,
                           const float* input, std::size_t inputFrames,
                           float* output, std::size_t frameOffset, std::size_t count) noexcept {
    if (state == nullptr || segments == nullptr || segmentCount == 0 || input == nullptr || output == nullptr) {
        return;
    }
    TemporalShatterState& s = *state;
    const double rate = controls.sampleRate;
    const double fade = std::max(1.0, crossfadeSeconds * rate);
    for (std::size_t i = 0; i < count; ++i) {
        const std::size_t frame = frameOffset + i;
        const auto n = static_cast<double>(frame);
        while (s.segment + 1 < segmentCount && segments[s.segment + 1].outputStart <= n) {
            ++s.segment;
        }
        const TemporalShatterSegment& piece = segments[s.segment];
        const double position = piece.sourceStart + (n - piece.outputStart) * piece.speed;
        const float tape = timeMapRead(input, inputFrames, position);
        float value = tape;
        if (controls.mode == TemporalShatterMode::grains) {
            // Grains run all along, so they're in step when a tail begins.
            int grainFrames = static_cast<int>(std::lround(controls.grain.valueAt(frame) * 0.001 * rate));
            grainFrames = std::max(2, grainFrames + (grainFrames & 1));
            if (frame >= s.nextLaunch) {
                s.grains.launch(input, inputFrames, position, grainFrames);
                s.nextLaunch = frame + static_cast<std::size_t>(grainFrames / 2);
            }
            const float grains = s.grains.read(input, inputFrames, grainFrames, true);
            if (!piece.anchor) {
                // Anchors stay bit-faithful; a tail after an anchor fades from tape to grains over 2 ms.
                const bool afterAnchor = s.segment > 0 && segments[s.segment - 1].anchor;
                const double blend = afterAnchor ? std::min(1.0, (n - piece.outputStart) / fade) : 1.0;
                value = static_cast<float>(tape + (grains - tape) * blend);
            }
        }
        output[i] = std::isfinite(value) ? value : 0.0f;
    }
}

} // namespace bake::dsp
