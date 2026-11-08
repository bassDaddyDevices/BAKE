/// Step FX's pattern: one character per step, spaces ignored. The renderer (`BakeDSP/StepFX.h`)
/// takes the effect indices; the card's step cells read and write the same text.
public enum StepFXPattern {
    /// In `StepEffect` order (index 0 is Pass).
    public enum Effect: Int, CaseIterable, Sendable {
        case pass, stutter, reverse, tapeStop, halfTime, gate

        public var symbol: Character {
            switch self {
            case .pass: "·"
            case .stutter: "S"
            case .reverse: "R"
            case .tapeStop: "T"
            case .halfTime: "H"
            case .gate: "G"
            }
        }

        public var name: String {
            switch self {
            case .pass: "Pass"
            case .stutter: "Stutter"
            case .reverse: "Reverse"
            case .tapeStop: "Tape Stop"
            case .halfTime: "Half Time"
            case .gate: "Gate"
            }
        }

        /// The next effect when a cell is clicked.
        public var next: Effect { Effect(rawValue: (rawValue + 1) % Effect.allCases.count) ?? .pass }
    }

    public static let maximumSteps = 32
    /// Step lengths when no Clock is wired, in Beat Repeat's note values.
    public static let stepLengths = ["1/4", "1/8", "1/8t", "1/16", "1/16t", "1/32", "1/64"]

    /// The first `steps` effects of `text`; missing steps, and characters that aren't effects, are Pass.
    public static func effects(_ text: String, steps: Int) -> [Effect] {
        let parsed = parse(text)
        let count = min(max(steps, 1), maximumSteps)
        return (0..<count).map { $0 < parsed.count ? parsed[$0] : .pass }
    }

    private static func parse(_ text: String) -> [Effect] {
        text.compactMap { character -> Effect? in
            switch character.uppercased() {
            case "·", ".", "-", "_": .pass
            case "S": .stutter
            case "R": .reverse
            case "T": .tapeStop
            case "H": .halfTime
            case "G": .gate
            default: nil
            }
        }
    }

    /// The text for `effects`, one symbol per step separated by spaces.
    public static func text(_ effects: [Effect]) -> String {
        effects.map { String($0.symbol) }.joined(separator: " ")
    }

    /// `text` with one step changed. Steps past the current Steps count keep their effects, as hidden
    /// controls keep their values.
    public static func setting(_ index: Int, to effect: Effect, in text: String, steps: Int) -> String {
        var current = effects(text, steps: max(parse(text).count, steps, index + 1))
        guard current.indices.contains(index) else { return text }
        current[index] = effect
        return self.text(current)
    }
}
