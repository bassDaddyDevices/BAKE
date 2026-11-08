import Foundation

/// The Resonator node's settings, in musical units.
public struct ResonatorSettings: Equatable, Sendable {
    public var rootHz: Double
    public var fineCents: Double
    /// Seconds for each band to ring down 60 dB.
    public var decaySeconds: Double
    /// 0 = pure harmonic series, 1 = strongly stretched (bell-like) partials.
    public var inharmonicity: Double
    public var bands: Int
    /// One-pole low-pass inside each loop: 0 = bright, toward 1 = dark.
    public var damping: Double
    /// Soft-clip blend inside each loop: 0 = clean, 1 = fully saturated.
    public var saturation: Double
    /// 0 = dry input only, 1 = resonance only.
    public var mix: Double

    public init(
        rootHz: Double = 110, fineCents: Double = 0, decaySeconds: Double = 2, inharmonicity: Double = 0,
        bands: Int = 64, damping: Double = 0.2, saturation: Double = 0, mix: Double = 1
    ) {
        self.rootHz = rootHz
        self.fineCents = fineCents
        self.decaySeconds = decaySeconds
        self.inharmonicity = inharmonicity
        self.bands = bands
        self.damping = damping
        self.saturation = saturation
        self.mix = mix
    }
}

/// One comb line's tuning.
public struct ResonatorBandTuning: Equatable, Sendable {
    public let frequency: Double
    /// Delay in samples (fractional).
    public let delay: Float
    /// Gain applied on each trip around the loop.
    public let feedback: Float
    /// Inactive bands are above the safe frequency limit and stay silent.
    public let isActive: Bool
}

public enum ResonatorTuning {
    /// Partials above this fraction of the sample rate are silenced, which also keeps every
    /// active delay above 2 samples.
    public static let maximumFrequencyRatio = 0.45

    /// Pole of the DC blocker inside every comb loop (≈ 4 Hz corner at 48 kHz). A feedback comb
    /// resonates at 0 Hz as well as at its pitch; without this, summed bands build a large offset.
    public static let dcBlockerPole: Float = 0.9995

    /// Stiff-string partial series: fₙ = f₀ · n · √(1 + B·n²), B = inharmonicity × 0.001.
    public static func bands(for settings: ResonatorSettings, sampleRate: Double) -> [ResonatorBandTuning] {
        let fundamental = settings.rootHz * pow(2, settings.fineCents / 1_200)
        let stiffness = settings.inharmonicity * 0.001
        return (1...max(settings.bands, 1)).map { number in
            let n = Double(number)
            let frequency = fundamental * n * (1 + stiffness * n * n).squareRoot()
            let delay = sampleRate / frequency
            // Per-trip gain so the line falls 60 dB (×0.001) over `decaySeconds`.
            let feedback = pow(10, -3 * delay / (settings.decaySeconds * sampleRate))
            return ResonatorBandTuning(
                frequency: frequency,
                delay: Float(delay),
                feedback: Float(feedback),
                isActive: frequency <= sampleRate * maximumFrequencyRatio
            )
        }
    }

    /// Samples per delay line: the longest active delay, rounded up, plus room to interpolate.
    public static func delayCapacity(for bands: [ResonatorBandTuning]) -> Int {
        let longest = bands.filter(\.isActive).map(\.delay).max() ?? 2
        return Int(longest.rounded(.up)) + 2
    }
}
