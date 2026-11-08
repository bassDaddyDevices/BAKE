import Foundation

/// Where Corpus Scatter puts its grains, from its settings alone, so the render and the card's onset dots
/// agree. Every choice (when, which clip, pitch, pan) is a counter hash of the Seed and the grain's number,
/// so the same settings give the same schedule.
public enum ScatterSchedule {
    public struct Grain: Equatable, Sendable {
        public var start: Int
        public var clip: Int
        public var semitones: Double
        public var pan: Double
    }

    /// The most grains one scatter places.
    public static let maximumGrains = 1_000_000

    /// The grains of a scatter over `clips` clips, `start` in frames at `sampleRate`, for the first
    /// `seconds` (Total Duration when nil).
    public static func grains(
        clips: Int, parameters: [ParameterID: ParameterValue], sampleRate: Double, seconds: Double? = nil
    ) -> [Grain] {
        guard clips > 0 else { return [] }
        let duration = min(parameters["duration"]?.numberValue ?? 10, seconds ?? .infinity)
        let seed = UInt64(max(0, parameters["seed"]?.numberValue ?? 1))
        let density = max(parameters["density"]?.numberValue ?? 8, 0.001)
        let pitch = parameters["pitchJitter"]?.numberValue ?? 0
        let spread = (parameters["panSpread"]?.numberValue ?? 50) / 100
        let inOrder = parameters["pick"] == .choice("inOrder")
        // 0…1 or −1…1 for grain `k`, draw `salt` (0 timing, 1 clip, 2 pitch, 3 pan).
        func unit(_ k: Int, _ salt: UInt64) -> Double { Double(hash((seed << 40) ^ (UInt64(k) << 8) ^ salt) >> 11) * 0x1.0p-53 }
        func signed(_ k: Int, _ salt: UInt64) -> Double { unit(k, salt) * 2 - 1 }

        var times: [Double] = []
        switch parameters["distribution"] {
        case .choice("uniform")?:
            let jitter = (parameters["timingJitter"]?.numberValue ?? 0) / 100
            var k = 0
            while times.count < maximumGrains {
                let time = (Double(k) + jitter * signed(k, 0) * 0.5) / density
                if Double(k) / density >= duration { break }
                times.append(max(0, time))
                k += 1
            }
        case .choice("euclidean")?:
            let steps = max(2, Int(parameters["steps"]?.numberValue ?? 16))
            let pulses = min(steps, max(1, Int(parameters["pulses"]?.numberValue ?? 5)))
            let step = (parameters["step"]?.numberValue ?? 125) / 1_000
            var index = 0
            while Double(index) * step < duration, times.count < maximumGrains {
                if (index % steps * pulses) % steps < pulses { times.append(Double(index) * step) }
                index += 1
            }
        default:
            var time = 0.0
            var k = 0
            while times.count < maximumGrains {
                time += -log(1 - unit(k, 0)) / density
                if time >= duration { break }
                times.append(time)
                k += 1
            }
        }
        return times.enumerated().map { k, time in
            Grain(
                start: Int((time * sampleRate).rounded()),
                clip: inOrder ? k % clips : Int(hash((seed << 40) ^ (UInt64(k) << 8) ^ 1) % UInt64(clips)),
                semitones: signed(k, 2) * pitch,
                pan: signed(k, 3) * spread
            )
        }
    }

    /// splitmix64's finaliser.
    public static func hash(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }
}
