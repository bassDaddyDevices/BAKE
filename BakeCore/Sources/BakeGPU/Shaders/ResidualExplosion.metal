#include <metal_stdlib>
using namespace metal;

/// The settings at one frame; mirrors `ResidualFrame` in ResidualExplosionKernel.swift.
struct ResidualFrame {
    float levels;        // Collapse: 2^(bits − 1) steps per unit
    float inverseLevels; // 1 / levels
    float threshold;     // Sparsify: linear threshold
    float gain;          // linear residual gain
    float body;
    float mix;
    uint mode;           // 0 = collapse, 1 = sparsify
};

/// Mirrors `ResidualUniforms` in ResidualExplosionKernel.swift.
struct ResidualUniforms {
    uint frames;
    uint channels;
    uint inputOffset;
    uint inputChannelStride;
    uint outputOffset;
    uint outputChannelStride;
    uint perFrame; // 1: table[frame], 0: table[0]
};

/// The wet signal for one sample: simplify, take what was thrown away, amplify it under a tanh ceiling.
static float residualWet(float x, ResidualFrame p) {
    // Multiply by 1/L rather than divide: fast-math division is approximate.
    const float simplified = p.mode == 0 ? round(x * p.levels) * p.inverseLevels
                                         : (fabs(x) < p.threshold ? 0.0f : x);
    return p.body * simplified + precise::tanh(p.gain * (x - simplified));
}

/// Residual Explosion without oversampling. One thread per (frame, channel); stateless, so any
/// chunking gives the same bits.
kernel void residualExplosion(device const float* input [[buffer(0)]],
                              device float* output [[buffer(1)]],
                              device const ResidualFrame* table [[buffer(2)]],
                              constant ResidualUniforms& u [[buffer(3)]],
                              uint2 id [[thread_position_in_grid]]) {
    if (id.x >= u.frames || id.y >= u.channels) {
        return;
    }
    const ResidualFrame p = table[u.perFrame != 0 ? id.x : 0];
    const float x = input[id.y * u.inputChannelStride + u.inputOffset + id.x];
    output[id.y * u.outputChannelStride + u.outputOffset + id.x] = p.mix * residualWet(x, p) + (1.0f - p.mix) * x;
}

/// Mirrors `ResidualOversampledUniforms` in ResidualExplosionKernel.swift.
struct ResidualOversampledUniforms {
    uint frames;              // base-rate frames in this sub-chunk
    uint channels;
    uint start;               // first base-rate frame
    uint inputFrames;         // frames in each input channel (reads outside are silence)
    uint inputChannelStride;
    uint outputChannelStride;
    uint factor;
    uint length;              // taps: 64 × factor + 1
    uint highCount;           // upsampled samples this sub-chunk needs
    uint highStride;          // floats per channel in `high`
    int tableStart;           // base-rate frame of table[0] when perFrame
    uint perFrame;
};

static long floorDivide(long value, long divisor) {
    const long quotient = value / divisor;
    return (value % divisor != 0 && value < 0) ? quotient - 1 : quotient;
}

static ResidualFrame frameAt(device const ResidualFrame* table, constant ResidualOversampledUniforms& u, long frame) {
    return table[u.perFrame != 0 ? uint(frame - long(u.tableStart)) : 0];
}

/// Oversampled pass 1, one thread per (upsampled sample, channel): interpolate with the shared Kaiser
/// filter (reading the whole input, so there is no latency), then shape at the high rate. Mirrors
/// `renderOversampled` in BakeDSP/Oversampling.h.
kernel void residualExplosionUp(device const float* input [[buffer(0)]],
                                device float* high [[buffer(1)]],
                                device const ResidualFrame* table [[buffer(2)]],
                                constant ResidualOversampledUniforms& u [[buffer(3)]],
                                device const float* taps [[buffer(4)]],
                                uint2 id [[thread_position_in_grid]]) {
    if (id.x >= u.highCount || id.y >= u.channels) {
        return;
    }
    const long factor = long(u.factor);
    const long center = long(u.length) / 2;
    const long m = long(u.start) * factor - center + long(id.x);
    const long lowest = floorDivide(m + center - (long(u.length) - 1) + factor - 1, factor);
    const long highest = floorDivide(m + center, factor);
    device const float* channel = input + id.y * u.inputChannelStride;
    float sum = 0;
    for (long b = max(lowest, 0L); b <= min(highest, long(u.inputFrames) - 1); ++b) {
        sum += taps[m + center - b * factor] * channel[b];
    }
    const ResidualFrame p = frameAt(table, u, max(0L, floorDivide(m, factor)));
    high[id.y * u.highStride + id.x] = residualWet(sum * float(u.factor), p);
}

/// Oversampled pass 2, one thread per (frame, channel): filter and decimate, then Mix at the base rate
/// against the untouched input, so Mix 0 is exact.
kernel void residualExplosionDown(device const float* input [[buffer(0)]],
                                  device const float* high [[buffer(1)]],
                                  device const ResidualFrame* table [[buffer(2)]],
                                  constant ResidualOversampledUniforms& u [[buffer(3)]],
                                  device const float* taps [[buffer(4)]],
                                  device float* output [[buffer(5)]],
                                  uint2 id [[thread_position_in_grid]]) {
    if (id.x >= u.frames || id.y >= u.channels) {
        return;
    }
    const uint center = u.length / 2;
    device const float* row = high + id.y * u.highStride + id.x * u.factor + 2 * center;
    float sum = 0;
    for (uint k = 0; k < u.length; ++k) {
        sum += taps[k] * row[-long(k)];
    }
    const uint frame = u.start + id.x;
    const ResidualFrame p = frameAt(table, u, long(frame));
    const float x = input[id.y * u.inputChannelStride + frame];
    output[id.y * u.outputChannelStride + frame] = p.mix * sum + (1.0f - p.mix) * x;
}
