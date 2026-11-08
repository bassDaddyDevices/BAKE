#pragma once

#include <cstddef>

#include "BakeDSP/Modulation.h"

namespace bake::dsp {

/// How the node interpolates between held samples (the `mode` Interpolation setting).
enum class ReduxMode : int { sampleAndHold = 0, linear = 1 };
/// `shaped` is triangular dither plus second-order error feedback, which pushes the quantisation
/// noise (and the dither) up out of the midrange: noise transfer function (1 - z^-1)^2.
enum class ReduxDither : int { off = 0, triangular = 1, shaped = 2 };

/// What the node does (the `reduxMode` Mode setting).
enum class ReduxAlgorithm : int {
    classic = 0,       ///< Bit Depth and Rate Divider together (the shipped behaviour).
    bitReduction = 1,  ///< Bit Depth only; Rate Divider ignored.
    downsampling = 2,  ///< Anti-aliased rate reduction, then Interpolation.
    sampleAndHold = 3, ///< Hold every Rate Divider-th sample, no quantising.
    bitwise = 4,       ///< Bitwise Operator with Mask on the integer sample.
};

enum class ReduxBitwiseOp : int { bitAnd = 0, bitOr = 1, bitXor = 2 };

/// Anti-alias low-pass sections for Downsampling (8-pole, 48 dB/oct).
inline constexpr int reduxAntiAliasSections = 4;

/// Carried between chunks. The anti-alias memory is only used by Downsampling.
struct ReduxState {
    float previous = 0;
    float current = 0;
    int phase = 0;
    int interval = 1;
    bool initialized = false;
    float lowZ1[reduxAntiAliasSections] = {};
    float lowZ2[reduxAntiAliasSections] = {};
    /// The last two quantisation errors, fed back by `ReduxDither::shaped`.
    float shapeError[2] = {};
};

/// Settings added after the first release. A default-constructed value is the original behaviour.
struct ReduxOptions {
    /// Bit Depth keeps its fraction (3.5 bits = 2^2.5 levels per side) instead of rounding to whole bits.
    bool fractionalBits = false;
    /// The input already low-passed for Downsampling (chunk-relative, `count` floats), e.g. by the
    /// linear-phase filter. Null uses the built-in biquad cascade.
    const float* antiAliased = nullptr;
};

/// Bit-crush and rate-reduce one channel. `algorithm` is the Mode setting and `mode` the
/// Interpolation setting; classic reproduces the shipped Bit Depth + Rate Divider behaviour exactly.
/// Dither is generated from absolute frame and channel, so rendering is deterministic and
/// chunk-invariant. `sampleRate` is needed for the Downsampling anti-alias cutoff.
/// Modulation for the controls that used to be fixed: Mode and Operator are choice indexes (the
/// enums' order); Mask is an integer. Each applies only while its signal is modulated.
struct ReduxModulation {
    ParameterSignal algorithm;
    ParameterSignal bitwiseOp;
    ParameterSignal mask;
};

void renderRedux(ReduxState& state, ReduxAlgorithm algorithm, ReduxMode mode, ReduxDither dither,
                 ReduxBitwiseOp bitwiseOp, int mask, const ReduxModulation& modulation,
                 const ParameterSignal& bitDepth, const ParameterSignal& rateDivider, const ParameterSignal& mix,
                 const float* input, float* output, std::size_t frameOffset, std::size_t count,
                 std::size_t channel, double sampleRate, const ReduxOptions& options) noexcept;

void renderRedux(ReduxState& state, ReduxAlgorithm algorithm, ReduxMode mode, ReduxDither dither,
                 ReduxBitwiseOp bitwiseOp, int mask, const ReduxModulation& modulation,
                 const ParameterSignal& bitDepth, const ParameterSignal& rateDivider, const ParameterSignal& mix,
                 const float* input, float* output, std::size_t frameOffset, std::size_t count,
                 std::size_t channel, double sampleRate) noexcept;

void renderRedux(ReduxState& state, ReduxAlgorithm algorithm, ReduxMode mode, ReduxDither dither,
                 ReduxBitwiseOp bitwiseOp, int mask,
                 const ParameterSignal& bitDepth, const ParameterSignal& rateDivider, const ParameterSignal& mix,
                 const float* input, float* output, std::size_t frameOffset, std::size_t count,
                 std::size_t channel, double sampleRate) noexcept;

} // namespace bake::dsp
