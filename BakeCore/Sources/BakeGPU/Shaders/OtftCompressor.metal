#include <metal_stdlib>
using namespace metal;

// No fused multiply-add or reassociation: the arithmetic must follow the CPU reference (otftGainColumns in OtftCompressor.cpp).
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)

/// What a frame asks of every unit; mirrors `OtftFrameParams` in OtftCompressor.h and `OtftGPUFrame` in OtftKernel.swift.
struct OtftFrameParams {
    float downThreshold;
    float downSlope;
    float upThreshold;
    float upSlope;
    float maxBoost;
    float attackMs;
    float releaseMs;
    float padding;
};

/// Mirrors `OtftEnvelope` (plus the sizes) and `OtftGPUUniforms` in OtftKernel.swift.
struct OtftUniforms {
    uint frames;
    uint units;
    float hopMilliseconds;
    float kneeDb;
    uint anticipating;
    uint smoothFrames;
};

constant float otftFloorDb = -120.0f;

static float otftCurveReduction(float x, float slope, float knee) {
    if (knee > 0.0f && 2.0f * x < -knee) {
        return 0.0f;
    }
    if (knee > 0.0f && 2.0f * fabs(x) <= knee) {
        const float shifted = x + knee * 0.5f;
        return slope * shifted * shifted / (2.0f * knee);
    }
    return x > 0.0f ? slope * x : 0.0f;
}

static float otftCoefficient(float hopMilliseconds, float milliseconds, float scale) {
    const float time = milliseconds * scale;
    return time <= 1e-6f ? 0.0f : exp(-hopMilliseconds / time);
}

static float otftGainDb(float levelDb, OtftFrameParams frame, float offsetDb, float kneeDb) {
    const float reduction = otftCurveReduction(levelDb - (frame.downThreshold + offsetDb), frame.downSlope, kneeDb);
    const float boost = min(otftCurveReduction((frame.upThreshold + offsetDb) - levelDb, frame.upSlope, kneeDb), frame.maxBoost);
    return boost - reduction;
}

/// The follower and the gain computer, one thread per unit looping over every frame, in place on `surface`
/// (frame-major: `surface[frame * units + unit]`; levels in, gain in dB out).
kernel void otftEnvelope(device float* surface [[buffer(0)]],
                         constant OtftFrameParams* frames [[buffer(1)]],
                         constant OtftUniforms& uniforms [[buffer(2)]],
                         constant float* timeScale [[buffer(3)]],
                         constant float* offsetDb [[buffer(4)]],
                         uint unit [[thread_position_in_grid]]) {
    if (unit >= uniforms.units) {
        return;
    }
    const float scale = timeScale[unit];
    const float offset = offsetDb[unit];
    const float hop = uniforms.hopMilliseconds;
    if (uniforms.anticipating != 0) {
        float carried = 0.0f;
        for (uint t = uniforms.frames; t-- > 0;) {
            const OtftFrameParams frame = frames[t];
            const float a = otftCoefficient(hop, frame.attackMs, scale);
            const float wanted = frame.maxBoost - otftGainDb(surface[t * uniforms.units + unit], frame, offset, uniforms.kneeDb);
            carried = max(wanted, carried * a);
            surface[t * uniforms.units + unit] = carried;
        }
        float held = 0.0f;
        for (uint t = 0; t < uniforms.frames; ++t) {
            const OtftFrameParams frame = frames[t];
            const float r = otftCoefficient(hop, frame.releaseMs, scale);
            const float target = surface[t * uniforms.units + unit];
            held = target >= held ? target : target + (held - target) * r;
            surface[t * uniforms.units + unit] = frame.maxBoost - held;
        }
    } else {
        float state = otftFloorDb;
        for (uint t = 0; t < uniforms.frames; ++t) {
            const OtftFrameParams frame = frames[t];
            const float level = surface[t * uniforms.units + unit];
            const float c = otftCoefficient(hop, level > state ? frame.attackMs : frame.releaseMs, scale);
            state = level + (state - level) * c;
            surface[t * uniforms.units + unit] = otftGainDb(state, frame, offset, uniforms.kneeDb);
        }
    }
}

/// A running mean of the gain over ±`smoothFrames` frames with the edges held, one thread per unit. Reads `source`,
/// writes `result` (a different buffer: the mean needs the unsmoothed neighbours).
kernel void otftSmooth(device const float* source [[buffer(0)]],
                       device float* result [[buffer(1)]],
                       constant OtftUniforms& uniforms [[buffer(2)]],
                       uint unit [[thread_position_in_grid]]) {
    if (unit >= uniforms.units) {
        return;
    }
    const int radius = int(uniforms.smoothFrames);
    const int n = int(uniforms.frames);
    float sum = 0.0f;
    for (int k = -radius; k <= radius; ++k) {
        sum += source[uint(clamp(k, 0, n - 1)) * uniforms.units + unit];
    }
    const float width = float(2 * radius + 1);
    for (int t = 0; t < n; ++t) {
        result[uint(t) * uniforms.units + unit] = sum / width;
        sum += source[uint(clamp(t + radius + 1, 0, n - 1)) * uniforms.units + unit]
            - source[uint(clamp(t - radius, 0, n - 1)) * uniforms.units + unit];
    }
}
