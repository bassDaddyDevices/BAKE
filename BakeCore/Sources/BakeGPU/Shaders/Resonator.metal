#include <metal_stdlib>
using namespace metal;

/// Must match `ResonatorBandParameters` in ResonatorKernel.swift (12 bytes).
struct ResonatorBand {
    float delay;     // samples, fractional
    float feedback;  // per-trip gain
    uint  active;    // 0 = silent band
};

/// Must match `ResonatorUniforms` in ResonatorKernel.swift (48 bytes).
struct ResonatorUniforms {
    uint  bands;
    uint  channels;
    uint  frames;              // frames in this sub-chunk
    uint  delayCapacity;       // samples per delay line
    uint  inputOffset;         // float index of this sub-chunk's first frame, channel 0
    uint  inputChannelStride;  // floats between channels (planar)
    uint  outputOffset;
    uint  outputChannelStride;
    uint  rowCapacity;         // floats per band row in the scratch buffer
    float damping;
    float saturation;
    float normalization;       // 1 / active bands
    float dcBlockerPole;       // ≈ 4 Hz high-pass inside the loop
    float wet;                 // 0 = dry, 1 = resonance only
};

/// Per-line filter state carried across chunks: low-pass memory and DC-blocker memory.
struct LoopState {
    float lowpass;
    float dcInput;
    float dcOutput;
};

/// Pass 1: one thread per (channel, band) runs its comb line over the sub-chunk,
/// writing only its own row. Delay line, write head, and loop filter state persist across chunks.
kernel void resonatorBands(device const float*          input       [[buffer(0)]],
                           device float*                rows        [[buffer(1)]],
                           device float*                delayLines  [[buffer(2)]],
                           device uint*                 writeHeads  [[buffer(3)]],
                           device LoopState*            loopStates  [[buffer(4)]],
                           device const ResonatorBand*  bandTable   [[buffer(5)]],
                           constant ResonatorUniforms&  u           [[buffer(6)]],
                           uint line [[thread_position_in_grid]]) {
    if (line >= u.bands * u.channels) {
        return;
    }
    uint channel = line / u.bands;
    ResonatorBand band = bandTable[line % u.bands];
    device float* row = rows + line * u.rowCapacity;
    if (band.active == 0) {
        for (uint i = 0; i < u.frames; i++) {
            row[i] = 0.0f;
        }
        return;
    }

    device const float* x = input + u.inputOffset + channel * u.inputChannelStride;
    device float* delayLine = delayLines + line * u.delayCapacity;
    uint write = writeHeads[line];
    LoopState state = loopStates[line];

    for (uint i = 0; i < u.frames; i++) {
        // Read `delay` samples behind the write head, linearly interpolated.
        float readPosition = float(write) + float(u.delayCapacity) - band.delay;
        uint i0 = uint(readPosition) % u.delayCapacity;
        uint i1 = (i0 + 1) % u.delayCapacity;
        float fraction = readPosition - floor(readPosition);
        float delayed = delayLine[i0] + (delayLine[i1] - delayLine[i0]) * fraction;

        state.lowpass = delayed + (state.lowpass - delayed) * u.damping;
        float looped = state.lowpass * band.feedback;
        // DC blocker: a feedback comb also resonates at 0 Hz; keep it from building up.
        float blocked = looped - state.dcInput + u.dcBlockerPole * state.dcOutput;
        state.dcInput = looped;
        state.dcOutput = blocked;
        float feedback = blocked + (tanh(blocked) - blocked) * u.saturation;
        float y = x[i] + feedback;

        delayLine[write] = y;
        write = (write + 1) % u.delayCapacity;
        row[i] = y;
    }
    writeHeads[line] = write;
    loopStates[line] = state;
}

/// Pass 2: one thread per (frame, channel) sums that channel's band rows.
kernel void resonatorMix(device const float*         rows   [[buffer(0)]],
                         device float*               output [[buffer(1)]],
                         constant ResonatorUniforms& u      [[buffer(2)]],
                         device const float*         input  [[buffer(3)]],
                         uint2 position [[thread_position_in_grid]]) {
    uint frame = position.x;
    uint channel = position.y;
    if (frame >= u.frames || channel >= u.channels) {
        return;
    }
    float sum = 0.0f;
    for (uint band = 0; band < u.bands; band++) {
        sum += rows[(channel * u.bands + band) * u.rowCapacity + frame];
    }
    // Each thread reads, then writes, only its own element, so input and output may alias.
    float dry = input[u.inputOffset + channel * u.inputChannelStride + frame];
    output[u.outputOffset + channel * u.outputChannelStride + frame] = dry * (1.0f - u.wet) + sum * u.normalization * u.wet;
}

/// Pass 1 with modulated tuning: `bandTable` holds one row of bands per block of `blocks.x` frames,
/// blocks counted on absolute frames (`blocks.y` is this sub-chunk's first frame within its block), so
/// any chunking retunes at the same frames. Otherwise as `resonatorBands`.
kernel void resonatorBandsBlocked(device const float*          input       [[buffer(0)]],
                                  device float*                rows        [[buffer(1)]],
                                  device float*                delayLines  [[buffer(2)]],
                                  device uint*                 writeHeads  [[buffer(3)]],
                                  device LoopState*            loopStates  [[buffer(4)]],
                                  device const ResonatorBand*  bandTable   [[buffer(5)]],
                                  constant ResonatorUniforms&  u           [[buffer(6)]],
                                  constant uint2&              blocks      [[buffer(7)]],
                                  uint line [[thread_position_in_grid]]) {
    if (line >= u.bands * u.channels) {
        return;
    }
    uint channel = line / u.bands;
    uint bandIndex = line % u.bands;
    device float* row = rows + line * u.rowCapacity;
    device const float* x = input + u.inputOffset + channel * u.inputChannelStride;
    device float* delayLine = delayLines + line * u.delayCapacity;
    uint write = writeHeads[line];
    LoopState state = loopStates[line];

    for (uint i = 0; i < u.frames; i++) {
        ResonatorBand band = bandTable[((i + blocks.y) / blocks.x) * u.bands + bandIndex];
        if (band.active == 0) {
            // Silent while above the limit, but the line keeps time so it can come back cleanly.
            delayLine[write] = 0.0f;
            write = (write + 1) % u.delayCapacity;
            row[i] = 0.0f;
            continue;
        }
        float readPosition = float(write) + float(u.delayCapacity) - band.delay;
        uint i0 = uint(readPosition) % u.delayCapacity;
        uint i1 = (i0 + 1) % u.delayCapacity;
        float fraction = readPosition - floor(readPosition);
        float delayed = delayLine[i0] + (delayLine[i1] - delayLine[i0]) * fraction;

        state.lowpass = delayed + (state.lowpass - delayed) * u.damping;
        float looped = state.lowpass * band.feedback;
        float blocked = looped - state.dcInput + u.dcBlockerPole * state.dcOutput;
        state.dcInput = looped;
        state.dcOutput = blocked;
        float feedback = blocked + (tanh(blocked) - blocked) * u.saturation;
        float y = x[i] + feedback;

        delayLine[write] = y;
        write = (write + 1) % u.delayCapacity;
        row[i] = y;
    }
    writeHeads[line] = write;
    loopStates[line] = state;
}

/// Pass 2 with per-frame gains: `wetGain` (normalisation × Mix) and `dryGain` (1 − Mix) for each frame.
kernel void resonatorMixGained(device const float*         rows    [[buffer(0)]],
                               device float*               output  [[buffer(1)]],
                               constant ResonatorUniforms& u       [[buffer(2)]],
                               device const float*         input   [[buffer(3)]],
                               device const float*         wetGain [[buffer(4)]],
                               device const float*         dryGain [[buffer(5)]],
                               uint2 position [[thread_position_in_grid]]) {
    uint frame = position.x;
    uint channel = position.y;
    if (frame >= u.frames || channel >= u.channels) {
        return;
    }
    float sum = 0.0f;
    for (uint band = 0; band < u.bands; band++) {
        sum += rows[(channel * u.bands + band) * u.rowCapacity + frame];
    }
    float dry = input[u.inputOffset + channel * u.inputChannelStride + frame];
    output[u.outputOffset + channel * u.outputChannelStride + frame] = dry * dryGain[frame] + sum * wetGain[frame];
}
