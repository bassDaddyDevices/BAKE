import BakeDSP

/// M0 smoke kernel proving Swift → C++ buffer passing. Replaced by the kernel contract in M3.
public enum Gain {
    public static func apply(_ gain: Float, to samples: inout [Float]) {
        samples.withUnsafeMutableBufferPointer { buffer in
            // The pointer is only valid inside this closure; C++ must not keep it.
            guard let base = buffer.baseAddress else { return }
            bake.dsp.applyGain(base, buffer.count, gain)
        }
    }
}
