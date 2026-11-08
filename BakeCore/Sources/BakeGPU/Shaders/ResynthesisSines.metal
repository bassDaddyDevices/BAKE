#include <metal_stdlib>
using namespace metal;

/// Mirrors `ResynthesisSineUniforms` in ResynthesisSineKernel.swift.
struct ResynthesisSineUniforms {
    uint count;        // samples to write
    int start;         // absolute index of the first of them
    int firstCentre;   // sample at which hop 0 starts
    int hop;           // samples per hop
    int firstHop;      // hop of region 0
    int hopCount;      // regions in `params`
    int lastHop;       // the table's last hop
    uint slots;        // entries reserved per region
};

constant uint entryFloats = 8;

/// The sine bank of Spectral Resynthesis: one thread per output sample, summing the partials of that sample's hop in slot order
/// (a fixed order, so the bits never depend on how a render was split). Each partial follows the cubic phase path the CPU walks,
/// held in turns so every float stays small: only the frequency term can grow large, and it is kept as a high and a low float,
/// with the product's rounding error recovered by fma, so the phase stays accurate to about 1e-6 radian across a 4096-sample hop.
kernel void resynthesisSines(device const float* params [[buffer(0)]],
                             device const uint* counts [[buffer(1)]],
                             device float* output [[buffer(2)]],
                             constant ResynthesisSineUniforms& u [[buffer(3)]],
                             uint id [[thread_position_in_grid]]) {
    if (id >= u.count) {
        return;
    }
    float sum = 0.0f;
    const int d = u.start + int(id) - u.firstCentre;
    if (d >= 0) {
        const int hop = d / u.hop;
        const int region = hop - u.firstHop;
        if (hop <= u.lastHop && region >= 0 && region < u.hopCount) {
            const float t = float(d - hop * u.hop);
            const float t2 = t * t;
            const float t3 = t2 * t;
            device const float* entry = params + (ulong(region) * ulong(u.slots)) * entryFloats;
            const uint active = counts[region];
            for (uint e = 0; e < active; ++e, entry += entryFloats) {
                const float product = t * entry[1];
                const float error = precise::fma(t, entry[1], -product);
                const float turns = entry[0] + (product - floor(product)) + error + t * entry[2]
                                  + t2 * entry[3] + t3 * entry[4];
                const float angle = (turns - floor(turns)) * 6.2831853071795864769f;
                sum += (entry[5] + entry[6] * t) * precise::cos(angle);
            }
        }
    }
    output[id] = sum;
}
