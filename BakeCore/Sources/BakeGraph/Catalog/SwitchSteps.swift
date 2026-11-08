/// The order a Switch visits its outputs (0-based). The C++ kernel (`BakeDSP/Switch.h`) makes the
/// same choices at render time; `SwitchTests` checks the two agree. The card draws from this.
public enum SwitchSteps {
    /// Output numbers from a typed pattern ("1 1 3 2 4"), 0-based. Numbers outside 1…outputs and
    /// anything that isn't a number are skipped.
    public static func pattern(_ text: String, outputs: Int) -> [Int] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline })
            .compactMap { Int($0) }
            .filter { (1...max(outputs, 1)).contains($0) }
            .map { $0 - 1 }
    }

    /// The first `count` steps as they play: step 1 first, then one step per bang. An empty pattern plays Forward.
    public static func sequence(order: String, outputs: Int, pattern: [Int] = [], seed: UInt32 = 0, count: Int) -> [Int] {
        let outputs = max(outputs, 1)
        let order = order == "pattern" && pattern.isEmpty ? "forward" : order
        var random = seed
        func next() -> Int {
            random = random &* 1_664_525 &+ 1_013_904_223
            return Int(random >> 8)
        }
        var steps: [Int] = []
        var current = 0
        var direction = 1
        var patternIndex = 0
        for step in 0..<max(count, 0) {
            if step == 0 {
                current = switch order {
                case "random": next() % outputs
                case "pattern": pattern[0]
                default: 0
                }
            } else {
                switch order {
                case "pingPong":
                    if !(0..<outputs).contains(current + direction) { direction = -direction }
                    current = outputs == 1 ? 0 : current + direction
                case "random":
                    // Any output but the current one.
                    if outputs > 1 {
                        let draw = next() % (outputs - 1)
                        current = draw >= current ? draw + 1 : draw
                    }
                case "pattern":
                    patternIndex = (patternIndex + 1) % pattern.count
                    current = pattern[patternIndex]
                default:
                    current = (current + 1) % outputs
                }
            }
            steps.append(current)
        }
        return steps
    }
}
