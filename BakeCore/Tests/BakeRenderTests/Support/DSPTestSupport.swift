import BakeDSP
import Foundation

/// An unmodulated parameter signal.
func signal(_ base: Float, _ minimum: Float, _ maximum: Float, scale: bake.dsp.ModulationScale = .linear) -> bake.dsp.ParameterSignal {
    var signal = bake.dsp.ParameterSignal()
    signal.base = base
    signal.minimum = minimum
    signal.maximum = maximum
    signal.scale = scale
    return signal
}

func sine(frequency: Double, frames: Int, amplitude: Float = 0.5, sampleRate: Double = 48_000) -> [Float] {
    (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
}

func decibels(_ ratio: Float) -> Float { 20 * log10(ratio) }
