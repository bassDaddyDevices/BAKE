#include "BakeDSP/WavetableFactory.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include "BakeDSP/Fft.h"

namespace bake::dsp {

namespace {

constexpr double pi = 3.14159265358979323846264338327950288;
constexpr std::size_t maximumFrameSize = 4096;

double unitHash(std::uint64_t seed, std::uint64_t index) noexcept {
    std::uint64_t z = seed * 0x9E3779B97F4A7C15ull + index;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return static_cast<double>(z >> 11) * (1.0 / 9007199254740992.0);
}

bool validSettings(const WavetableSettings& settings) noexcept {
    return settings.frameSize >= 256 && settings.frameSize <= maximumFrameSize
        && (settings.frameSize & (settings.frameSize - 1)) == 0
        && settings.slots >= 2 && settings.slots <= 256
        && settings.fragments >= 4 && settings.fragments <= 32
        && settings.frameSize % settings.fragments == 0;
}

/// How far a bin or fragment with random threshold `u` has moved from A to B at `fraction`: 0 at
/// fraction 0 and 1 at fraction 1 for every u, so adjacent source pairs join seamlessly. Each bin
/// crossfades over `width` of the way rather than flipping.
double switchWeight(double u, double fraction) noexcept {
    constexpr double width = 0.15;
    return std::clamp((fraction - u * (1.0 - width)) / width, 0.0, 1.0);
}

void fftFrame(double* real, double* imaginary, double* cosines, double* sines, std::size_t size) noexcept {
    fftTwiddles(size, cosines, sines);
    fft(real, imaginary, size, cosines, sines);
}

void inverseReal(double* real, double* imaginary, double* cosines, double* sines, std::size_t size) noexcept {
    real[0] = std::isfinite(real[0]) ? real[0] : 0.0;
    imaginary[0] = 0.0;
    imaginary[size / 2] = 0.0;
    for (std::size_t bin = 1; bin < size / 2; ++bin) {
        real[size - bin] = real[bin];
        imaginary[size - bin] = -imaginary[bin];
    }
    inverseFft(real, imaginary, size, cosines, sines);
}

float inputSample(const AudioInput& source, std::size_t frame) noexcept {
    if (!source.isWired()) {
        return 0.0f;
    }
    double sum = 0.0;
    for (std::size_t channel = 0; channel < source.channelCount; ++channel) {
        sum += source.sample(channel, frame);
    }
    return std::isfinite(sum) ? static_cast<float>(sum) : 0.0f;
}

void gatherFrames(const WavetableSettings& settings, const AudioInput* sources, std::size_t sourceCount,
                  float* sourceFrames, std::size_t sourceCapacityFrames, std::size_t& frameCount) noexcept {
    const std::size_t size = settings.frameSize;
    frameCount = 0;
    if (sources == nullptr || sourceFrames == nullptr || sourceCapacityFrames == 0) {
        return;
    }
    const std::size_t capacity = std::min(sourceCapacityFrames, settings.maxSourceFrames);
    for (std::size_t inputIndex = 0; inputIndex < sourceCount && frameCount < capacity; ++inputIndex) {
        const AudioInput& source = sources[inputIndex];
        if (!source.isWired()) {
            continue;
        }
        const std::size_t completeFrames = source.frames / size;
        const std::size_t remainder = source.frames % size;
        const bool onlyPartial = completeFrames == 0 && remainder > 0;
        const std::size_t framesForInput = completeFrames + (onlyPartial ? 1 : 0);
        for (std::size_t frame = 0; frame < framesForInput && frameCount < capacity; ++frame) {
            const std::size_t base = frameCount * size;
            const std::size_t start = frame * size;
            const std::size_t count = onlyPartial ? remainder : size;
            for (std::size_t sample = 0; sample < count; ++sample) {
                sourceFrames[base + sample] = inputSample(source, start + sample);
            }
            if (count < size) {
                std::fill(sourceFrames + base + count, sourceFrames + base + size, 0.0f);
            }
            ++frameCount;
        }
    }
    if (frameCount == 0) {
        std::fill(sourceFrames, sourceFrames + size, 0.0f);
        frameCount = 1;
    }
}

void morphLinear(const float* a, const float* b, float fraction, float* output, std::size_t size) noexcept {
    const float inverse = 1.0f - fraction;
    for (std::size_t i = 0; i < size; ++i) {
        output[i] = inverse * a[i] + fraction * b[i];
    }
}

void morphSpectral(const WavetableSettings& settings, const float* a, const float* b,
                   float fraction, float* output, double* realA, double* imaginaryA,
                   double* realB, double* imaginaryB, double* cosines, double* sines) noexcept {
    const std::size_t size = settings.frameSize;
    for (std::size_t i = 0; i < size; ++i) {
        realA[i] = a[i];
        imaginaryA[i] = 0.0;
        realB[i] = b[i];
        imaginaryB[i] = 0.0;
    }
    fftFrame(realA, imaginaryA, cosines, sines, size);
    fftFrame(realB, imaginaryB, cosines, sines, size);
    for (std::size_t i = 0; i <= size / 2; ++i) {
        const double ar = realA[i], ai = imaginaryA[i];
        const double br = realB[i], bi = imaginaryB[i];
        const double lerpReal = (1.0 - fraction) * ar + fraction * br;
        const double lerpImaginary = (1.0 - fraction) * ai + fraction * bi;
        const double magnitudeA = std::hypot(ar, ai);
        const double magnitudeB = std::hypot(br, bi);
        // Each bin has one fixed threshold, so as the table moves from A to B every bin switches
        // once and stays switched: a steady morph, seamless where one source pair hands over to the next.
        const double magnitude = magnitudeA + (magnitudeB - magnitudeA) * switchWeight(unitHash(settings.seed, i), fraction);
        const double angle = std::atan2(lerpImaginary, lerpReal);
        realA[i] = magnitude * std::cos(angle);
        imaginaryA[i] = magnitude * std::sin(angle);
    }
    inverseReal(realA, imaginaryA, cosines, sines, size);
    for (std::size_t i = 0; i < size; ++i) {
        output[i] = std::isfinite(realA[i]) ? static_cast<float>(realA[i]) : 0.0f;
    }
}

void morphFragments(const WavetableSettings& settings, const float* a, const float* b,
                    float fraction, float* output) noexcept {
    const std::size_t size = settings.frameSize;
    const std::size_t fragments = settings.fragments;
    const std::size_t fragmentSize = size / fragments;
    for (std::size_t i = 0; i < size; ++i) {
        const std::size_t fragment = std::min(i / fragmentSize, fragments - 1);
        // One fixed threshold per fragment, as for spectral bins: each fragment switches to B once.
        const float weight = static_cast<float>(switchWeight(unitHash(settings.seed ^ 0xF4ull, fragment), fraction));
        output[i] = a[i] + (b[i] - a[i]) * weight;
    }
    constexpr std::size_t crossfade = 16;
    for (std::size_t boundary = fragmentSize; boundary < size; boundary += fragmentSize) {
        const std::size_t half = crossfade / 2;
        const std::size_t start = boundary >= half ? boundary - half : 0;
        const std::size_t end = std::min(start + crossfade, size);
        const std::size_t leftFragment = boundary / fragmentSize - 1;
        const std::size_t rightFragment = boundary / fragmentSize;
        const float leftWeight = static_cast<float>(switchWeight(unitHash(settings.seed ^ 0xF4ull, leftFragment), fraction));
        const float rightWeight = static_cast<float>(switchWeight(unitHash(settings.seed ^ 0xF4ull, rightFragment), fraction));
        for (std::size_t i = start; i < end; ++i) {
            const float t = static_cast<float>(i - start) / static_cast<float>(std::max<std::size_t>(end - start - 1, 1));
            const float left = a[i] + (b[i] - a[i]) * leftWeight;
            const float right = a[i] + (b[i] - a[i]) * rightWeight;
            output[i] = (1.0f - t) * left + t * right;
        }
    }
}

void conditionSlot(const WavetableSettings& settings, std::size_t slot, float* frame,
                   double* real, double* imaginary, double* cosines, double* sines) noexcept {
    const std::size_t size = settings.frameSize;
    if (settings.dcRemoval == WavetableToggle::on) {
        double mean = 0.0;
        for (std::size_t i = 0; i < size; ++i) mean += frame[i];
        mean /= static_cast<double>(size);
        for (std::size_t i = 0; i < size; ++i) frame[i] -= static_cast<float>(mean);
    }
    if (settings.snap == WavetableToggle::on) {
        std::size_t best = size;
        std::size_t bestDistance = size;
        for (std::size_t i = 0; i < size; ++i) {
            const std::size_t next = (i + 1) % size;
            if (frame[i] <= 0.0f && frame[next] > 0.0f) {
                const std::size_t distance = std::min(i + 1, size - i - 1);
                if (distance < bestDistance) {
                    best = next;
                    bestDistance = distance;
                }
            }
        }
        if (best < size && best != 0) {
            const std::size_t rotation = best - 1;
            for (std::size_t i = 0; i < size; ++i) real[i] = frame[(rotation + i) % size];
            for (std::size_t i = 0; i < size; ++i) frame[i] = static_cast<float>(real[i]);
        }
    }
    if (settings.phase != WavetablePhase::keep) {
        for (std::size_t i = 0; i < size; ++i) {
            real[i] = frame[i];
            imaginary[i] = 0.0;
        }
        fftFrame(real, imaginary, cosines, sines, size);
        for (std::size_t bin = 0; bin <= size / 2; ++bin) {
            const double magnitude = std::hypot(real[bin], imaginary[bin]);
            double angle = -pi / 2.0;
            if (settings.phase == WavetablePhase::minimumCrest) {
                angle = pi * static_cast<double>(bin) * static_cast<double>(bin) / static_cast<double>(size / 2 + 1);
            } else if (settings.phase == WavetablePhase::random) {
                angle = 2.0 * pi * unitHash(settings.seed, bin);
            }
            real[bin] = magnitude * std::cos(angle);
            imaginary[bin] = magnitude * std::sin(angle);
        }
        inverseReal(real, imaginary, cosines, sines, size);
        for (std::size_t i = 0; i < size; ++i) frame[i] = static_cast<float>(real[i]);
    }
    if (settings.normalize == WavetableNormalize::perFrame) {
        float peak = 0.0f;
        for (std::size_t i = 0; i < size; ++i) peak = std::max(peak, std::fabs(frame[i]));
        if (peak >= 1e-6f) {
            for (std::size_t i = 0; i < size; ++i) frame[i] /= peak;
        }
    }
    (void)slot;
}

} // namespace

void buildWavetable(const WavetableSettings& settings, const AudioInput* sources, std::size_t sourceCount,
                    float* sourceFrames, std::size_t sourceCapacityFrames,
                    float* table, double* scratch) noexcept {
    if (!validSettings(settings) || sources == nullptr || table == nullptr || scratch == nullptr || sourceFrames == nullptr) {
        return;
    }
    const std::size_t size = settings.frameSize;
    const std::size_t tableFloats = size * settings.slots;
    double* real = scratch;
    double* imaginary = scratch + size;
    double* realB = scratch + 2 * size;
    double* imaginaryB = scratch + 3 * size;
    double* cosines = scratch + 4 * size;
    double* sines = cosines + size;
    std::size_t sourceFrameCount = 0;
    gatherFrames(settings, sources, sourceCount, sourceFrames, sourceCapacityFrames, sourceFrameCount);
    if (sourceFrameCount == 0) {
        std::fill(table, table + tableFloats, 0.0f);
        return;
    }
    for (std::size_t slot = 0; slot < settings.slots; ++slot) {
        const double position = static_cast<double>(slot) * static_cast<double>(sourceFrameCount - 1)
            / static_cast<double>(settings.slots - 1);
        const std::size_t aIndex = static_cast<std::size_t>(std::floor(position));
        const std::size_t bIndex = std::min(aIndex + 1, sourceFrameCount - 1);
        const float fraction = static_cast<float>(position - static_cast<double>(aIndex));
        const float* a = sourceFrames + aIndex * size;
        const float* b = sourceFrames + bIndex * size;
        float* frame = table + slot * size;
        switch (settings.morph) {
        case WavetableMorph::linear:
            morphLinear(a, b, fraction, frame, size);
            break;
        case WavetableMorph::spectral:
            morphSpectral(settings, a, b, fraction, frame, real, imaginary, realB, imaginaryB, cosines, sines);
            break;
        case WavetableMorph::fragments:
            morphFragments(settings, a, b, fraction, frame);
            break;
        }
        conditionSlot(settings, slot, frame, real, imaginary, cosines, sines);
    }
    if (settings.normalize == WavetableNormalize::table) {
        float peak = 0.0f;
        for (std::size_t i = 0; i < tableFloats; ++i) peak = std::max(peak, std::fabs(table[i]));
        if (peak >= 1e-6f) {
            for (std::size_t i = 0; i < tableFloats; ++i) table[i] /= peak;
        }
    }
}

} // namespace bake::dsp
