/// A Batch Bake's file name for one pass: `{source}` is the input file's name without its
/// extension, `{n}` the pass number from 1, zero-padded to the width of the pass count.
public enum BatchFileName {
    public static func resolve(_ pattern: String, source: String, pass: Int, count: Int) -> String {
        let digits = String(pass + 1)
        let number = String(repeating: "0", count: max(0, String(count).count - digits.count)) + digits
        let name = pattern
            .replacingOccurrences(of: "{source}", with: source)
            .replacingOccurrences(of: "{n}", with: number)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? source : name
    }

    /// Whether passes get different names; without a token, every pass writes the same name.
    public static func varies(_ pattern: String) -> Bool {
        pattern.contains("{source}") || pattern.contains("{n}")
    }
}
