#include <metal_stdlib>
using namespace metal;

/// Multiplies `count` samples in place. M2 smoke kernel proving the GPU engine works on the
/// shared buffer pool; the Resonator arrives in M3.
kernel void scaleInPlace(device float* samples [[buffer(0)]],
                         constant uint& count [[buffer(1)]],
                         constant float& factor [[buffer(2)]],
                         uint index [[thread_position_in_grid]]) {
    if (index >= count) {
        return; // Every kernel bounds-checks its thread index.
    }
    samples[index] *= factor;
}
