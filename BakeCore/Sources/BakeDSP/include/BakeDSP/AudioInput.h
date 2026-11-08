#pragma once

#include <cmath>
#include <cstddef>

namespace bake::dsp {

inline constexpr std::size_t maxAudioInputChannels = 8;

/// An audio input pin that may be shorter, or have fewer channels, than the node reading it
/// (Mixer, Channel Merger). Past its end it reads 0; non-finite samples read 0. The channel
/// pointers are borrowed from the render's buffer pool and never owned.
struct AudioInput {
    const float* channels[maxAudioInputChannels] = {};
    std::size_t channelCount = 0;
    std::size_t frames = 0;

    bool isWired() const noexcept { return channelCount > 0 && frames > 0; }

    /// Channel `channel` at an absolute frame, or 0 if the input has no such channel.
    float sample(std::size_t channel, std::size_t frame) const noexcept {
        if (channel >= channelCount || frame >= frames || channels[channel] == nullptr) {
            return 0.0f;
        }
        const float value = channels[channel][frame];
        return std::isfinite(value) ? value : 0.0f;
    }

    /// Like `sample`, but a mono input feeds every channel (how a Mixer spreads mono into stereo).
    float spread(std::size_t channel, std::size_t frame) const noexcept {
        return sample(channelCount == 1 ? 0 : channel, frame);
    }
};

} // namespace bake::dsp
