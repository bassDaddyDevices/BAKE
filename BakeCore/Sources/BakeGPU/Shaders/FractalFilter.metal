#include <metal_stdlib>
using namespace metal;

// No fused multiply-add or reassociation: the chaotic seeds must match the CPU reference bit for bit.
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)

/// Settings at one STFT frame; mirrors `FractalMaskFrame` in FractalFilterKernel.swift.
struct FractalMaskFrame {
    uint iterations;
    float warp;
    float center;
    float q;
    uint pattern; // 0 = Cantor, 1 = Mandelbrot, 2 = Julia, 3 = Koch
};

/// Mirrors `FractalMaskUniforms` in FractalFilterKernel.swift.
struct FractalMaskUniforms {
    uint frames;
    uint bins;
    uint binOffset;
    float binHz;
    float inverseLogSpan;
};

static float cantorSeed(float u) {
    for (uint i = 0; i < 5; ++i) {
        const float digit = floor(3.0f * u);
        if (digit == 1.0f) {
            return 0.0f;
        }
        u = fract(3.0f * u);
    }
    return 1.0f;
}

static float escapeSeed(float u, bool julia) {
    float2 z = julia ? float2(-1.5f + 3.0f * u, 0.0f) : float2(0.0f);
    const float2 c = julia ? float2(-0.8f, 0.156f) : float2(-2.0f + 2.5f * u, 0.25f);
    for (uint n = 0; n < 32; ++n) {
        if (dot(z, z) > 4.0f) {
            return float(n) * (1.0f / 32.0f);
        }
        z = float2(z.x * z.x - z.y * z.y, 2.0f * z.x * z.y) + c;
    }
    return 1.0f;
}

static float kochSeed(float u) {
    float sum = 0.0f;
    float weight = 1.0f;
    float frequency = 1.0f;
    for (uint i = 0; i < 5; ++i) {
        const float triangle = 1.0f - abs(2.0f * fract(frequency * u) - 1.0f);
        sum += weight * triangle;
        weight *= 0.5f;
        frequency *= 3.0f;
    }
    return sum * (16.0f / 31.0f);
}

static float patternSeed(float u, uint pattern) {
    switch (pattern) {
        case 0: return cantorSeed(u);
        case 1: return escapeSeed(u, false);
        case 2: return escapeSeed(u, true);
        default: return kochSeed(u);
    }
}

static float rawMask(float x, FractalMaskFrame p) {
    float mask = 1.0f;
    for (uint g = 1; g <= p.iterations; ++g) {
        const float scale = float(1u << g);
        const float u = fract(abs(x - p.center) * p.warp * scale);
        const float seed = patternSeed(u, p.pattern);
        const float texture = 0.03f + 0.97f * seed;
        // |sin(pi y)| = sin(pi fract(y)); scale * x is exact (a power of two), so this stays exact at 2^16.
        const float resonanceBase = precise::sin(M_PI_F * fract(scale * x));
        const float resonance = 1.0f + 3.0f * precise::pow(resonanceBase, 2.0f * p.q);
        mask *= texture * resonance;
    }
    return mask;
}

/// One thread per (STFT frame, frequency bin). Writes only the unnormalised raw mask.
kernel void fractalMask(device float* output [[buffer(0)]],
                        device const FractalMaskFrame* frameTable [[buffer(1)]],
                        constant FractalMaskUniforms& u [[buffer(2)]],
                        device const float* positions [[buffer(3)]],
                        uint2 id [[thread_position_in_grid]]) {
    if (id.x >= u.bins || id.y >= u.frames) {
        return;
    }

    // Log-frequency positions come from the CPU, so both sides start from identical bits.
    const float x = positions[u.binOffset + id.x];
    const float value = rawMask(x, frameTable[id.y]);
    output[id.y * u.bins + id.x] = value;
}
