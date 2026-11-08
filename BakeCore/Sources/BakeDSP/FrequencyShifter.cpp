#include "BakeDSP/FrequencyShifter.h"

#include <algorithm>
#include <cmath>

#include "BakeDSP/Fft.h"

namespace bake::dsp {
namespace {

constexpr double pi = 3.14159265358979323846;

double besselI0(double x) noexcept {
    double sum = 1, term = 1;
    for (int k = 1; k < 60; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        if (term < 1e-18 * sum) break;
    }
    return sum;
}

} // namespace

std::size_t hilbertTapCount(int precision) noexcept {
    switch (precision) {
    case 0: return 4097;
    case 2: return 262145;
    default: return 32769;
    }
}

std::size_t hilbertFftSize(int precision) noexcept {
    return nextPowerOfTwo(hilbertTapCount(precision) * 2);
}

std::size_t hilbertBlockFrames(int precision) noexcept {
    return hilbertFftSize(precision) - hilbertTapCount(precision) + 1;
}

std::size_t hilbertScratchDoubles(int precision) noexcept {
    return hilbertFftSize(precision) * 2;
}

std::size_t hilbertTableDoubles(int precision) noexcept {
    return hilbertFftSize(precision) * 3;
}

void hilbertDesign(int precision, double* tables) noexcept {
    const std::size_t taps = hilbertTapCount(precision);
    const std::size_t size = hilbertFftSize(precision);
    double* cosines = tables;
    double* sines = cosines + size / 2;
    double* real = sines + size / 2;
    double* imaginary = real + size;
    fftTwiddles(size, cosines, sines);
    std::fill(real, real + size, 0.0);
    std::fill(imaginary, imaginary + size, 0.0);
    // Ideal Hilbert: 2/(πk) at odd offsets k from the centre, 0 at even; Kaiser window; stored from index 0 (the
    // centre delay is removed in `hilbertBlock`).
    const long long centre = static_cast<long long>(taps / 2);
    const double beta = 9.0;
    const double norm = besselI0(beta);
    for (long long i = 0; i < static_cast<long long>(taps); ++i) {
        const long long k = i - centre;
        if ((k & 1) == 0) {
            continue;
        }
        const double r = static_cast<double>(k) / static_cast<double>(centre);
        const double window = besselI0(beta * std::sqrt(std::max(0.0, 1.0 - r * r))) / norm;
        real[i] = 2.0 / (pi * static_cast<double>(k)) * window;
    }
    fft(real, imaginary, size, cosines, sines);
}

void hilbertBlock(const AudioInput& input, std::size_t channel, int precision, const double* tables, double* scratch,
                  std::size_t firstFrame, std::size_t count, float* out) noexcept {
    if (out == nullptr || tables == nullptr || scratch == nullptr || count == 0) {
        return;
    }
    const std::size_t taps = hilbertTapCount(precision);
    const std::size_t size = hilbertFftSize(precision);
    const double* cosines = tables;
    const double* sines = cosines + size / 2;
    const double* kernelReal = sines + size / 2;
    const double* kernelImaginary = kernelReal + size;
    double* real = scratch;
    double* imaginary = scratch + size;
    // Output frame f needs input frames f ± centre. Load [firstFrame − centre, firstFrame − centre + size).
    const long long centre = static_cast<long long>(taps / 2);
    const long long start = static_cast<long long>(firstFrame) - centre;
    for (std::size_t i = 0; i < size; ++i) {
        const long long frame = start + static_cast<long long>(i);
        real[i] = (frame < 0 || frame >= static_cast<long long>(input.frames)) ? 0.0
            : static_cast<double>(input.sample(channel, static_cast<std::size_t>(frame)));
        imaginary[i] = 0.0;
    }
    fft(real, imaginary, size, cosines, sines);
    for (std::size_t k = 0; k < size; ++k) {
        const double a = real[k], b = imaginary[k];
        real[k] = a * kernelReal[k] - b * kernelImaginary[k];
        imaginary[k] = a * kernelImaginary[k] + b * kernelReal[k];
    }
    inverseFft(real, imaginary, size, cosines, sines);
    // The segment starts `centre` frames before the first output frame and the kernel's own centre is `centre` taps in,
    // so output frame firstFrame + j is at convolution index j + 2 × centre. Those are all clear of the wrap-around.
    for (std::size_t j = 0; j < count; ++j) {
        out[j] = static_cast<float>(real[j + 2 * static_cast<std::size_t>(centre)]);
    }
}

std::size_t shiftCheckpointCount(std::size_t frames) noexcept {
    return frames / shiftCheckpointSpacing + 2;
}

void shiftCheckpoints(const ParameterSignal& shift, bool absolute, double sampleRate, std::size_t frames, double* cycles) noexcept {
    if (cycles == nullptr) {
        return;
    }
    double phase = 0;
    const std::size_t count = shiftCheckpointCount(frames);
    for (std::size_t block = 0; block < count; ++block) {
        cycles[block] = phase;
        for (std::size_t i = 0; i < shiftCheckpointSpacing; ++i) {
            const std::size_t frame = block * shiftCheckpointSpacing + i;
            const double hertz = frame < frames ? static_cast<double>(shift.valueAt(frame)) : 0.0;
            phase += (absolute ? std::abs(hertz) : hertz) / sampleRate;
        }
        phase -= std::floor(phase);
    }
}

void shiftRender(const AudioInput& input, std::size_t channel, const float* hilbert, const ParameterSignal& shift,
                 bool absolute, double sign, double sampleRate, const double* checkpoints, std::size_t frameOffset,
                 std::size_t count, float* out, const ParameterSignal& mix, bool applyMix) noexcept {
    if (out == nullptr || count == 0) {
        return;
    }
    const std::size_t first = (frameOffset / shiftCheckpointSpacing) * shiftCheckpointSpacing;
    double phase = checkpoints != nullptr ? checkpoints[first / shiftCheckpointSpacing] : 0.0;
    for (std::size_t frame = first; frame < frameOffset + count; ++frame) {
        if (frame >= frameOffset) {
            const double angle = 2.0 * pi * sign * phase;
            const double x = input.sample(channel, frame);
            const double h = hilbert != nullptr ? static_cast<double>(hilbert[frame]) : 0.0;
            const double shifted = x * std::cos(angle) - h * std::sin(angle);
            const double amount = applyMix ? std::clamp(static_cast<double>(mix.valueAt(frame)), 0.0, 1.0) : 1.0;
            out[frame - frameOffset] = static_cast<float>(x + (shifted - x) * amount);
        }
        const double hertz = static_cast<double>(shift.valueAt(frame));
        phase += (absolute ? std::abs(hertz) : hertz) / sampleRate;
        // Wrap at each checkpoint so every chunk, whatever its start, sees the same running sum.
        if ((frame + 1) % shiftCheckpointSpacing == 0) {
            phase -= std::floor(phase);
        }
    }
}

} // namespace bake::dsp
