import Foundation

/// Where a Spectral Sorter sends a clip, from its measure: Low below Low Cutoff, High at or above High
/// Cutoff, Mid between. A clip with no measure goes where If Unmeasured says (nil: dropped).
public enum SorterRoute {
    public static func route(_ value: Double?, parameters: [ParameterID: ParameterValue]) -> PinID? {
        guard let value, value.isFinite else {
            if case .choice(let pin)? = parameters["unmeasured"], pin != "drop" { return PinID(pin) }
            return nil
        }
        let measure = measureName(parameters)
        let low = parameters[ParameterID("\(measure)Low")]?.numberValue ?? 0
        let high = max(low, parameters[ParameterID("\(measure)High")]?.numberValue ?? 0)
        return value < low ? "low" : value >= high ? "high" : "mid"
    }

    /// The Measure option: centroid, loudness, pitch or decay.
    public static func measureName(_ parameters: [ParameterID: ParameterValue]) -> String {
        if case .choice(let name)? = parameters["measure"] { name } else { "centroid" }
    }
}
