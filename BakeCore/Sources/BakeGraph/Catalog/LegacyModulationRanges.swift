/// The range and scale a modulated parameter had before its catalog range changed.
///
/// A modulation signal moves a parameter across its catalog range (`base + trim × signal × (max − min)`,
/// or in octaves for an exponential one), so widening a range changes what an already-wired patch sounds
/// like. Documents saved before a range changed are marked `modulationRange = legacy` by
/// `ProjectMigration`, and `ParameterSignal` uses the entry here instead of the catalog's range for them.
/// New nodes are marked `current`. Only ranges that changed belong here.
public enum LegacyModulationRanges {
    /// The hidden parameter carrying the mark.
    public static let parameterID: ParameterID = "modulationRange"
    public static let legacy = "legacy"
    public static let current = "current"

    public struct Entry: Equatable, Sendable {
        public let range: ClosedRange<Double>
        public let scale: ModulationScale
    }

    public static let entries: [NodeKind: [ParameterID: Entry]] = [
        .granularCloud: [
            "size": Entry(range: 5...500, scale: .linear),
            "density": Entry(range: 1...200, scale: .exponential),
            "spray": Entry(range: 0...2_000, scale: .linear),
        ],
        .stutter: [
            "repeats": Entry(range: 1...64, scale: .linear),
        ],
        .flanger: [
            "delay": Entry(range: 0.1...15, scale: .exponential),
        ],
    ]

    /// The entry to use for `parameter` of a node of `kind` with these parameters, or nil for the catalog's own range.
    public static func entry(kind: NodeKind, parameter: ParameterID, parameters: [ParameterID: ParameterValue]) -> Entry? {
        guard case .choice(Self.legacy)? = parameters[parameterID] else { return nil }
        return entries[kind]?[parameter]
    }
}
