import Foundation

/// The three lists a Random Words name is drawn from, `Adjective_Prefix_Suffix`.
public struct WordLists: Hashable, Sendable {
    public var adjectives: [String]
    public var prefixes: [String]
    public var suffixes: [String]

    public init(adjectives: [String], prefixes: [String], suffixes: [String]) {
        self.adjectives = adjectives
        self.prefixes = prefixes
        self.suffixes = suffixes
    }

    /// BAKE's own lists.
    public static let builtIn = WordLists(
        adjectives: BatchNames.builtInAdjectives, prefixes: BatchNames.builtInPrefixes, suffixes: BatchNames.builtInSuffixes
    )

    /// Lists from text, one word per line; blank lines and surrounding spaces are ignored, and spaces
    /// inside a word become underscores. Nil when any list ends up empty.
    public init?(adjectives: String, prefixes: String, suffixes: String) {
        func words(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_") }
                .filter { !$0.isEmpty }
        }
        let lists = (words(adjectives), words(prefixes), words(suffixes))
        guard !lists.0.isEmpty, !lists.1.isEmpty, !lists.2.isEmpty else { return nil }
        self.init(adjectives: lists.0, prefixes: lists.1, suffixes: lists.2)
    }

    /// How many different names the lists can make.
    public var combinations: Int { adjectives.count * prefixes.count * suffixes.count }
}

/// File names for a batch's passes: a typed name with a number, or random words.
public enum BatchNames {
    /// `Kick` → `Kick_001` (pass 0, 3 digits); more passes than the digits hold just get longer numbers.
    /// An empty name is `bake`.
    public static func numbered(_ name: String, pass: Int, digits: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let number = String(pass + 1)
        let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
        return "\(trimmed.isEmpty ? "bake" : trimmed)_\(padded)"
    }

    /// `Adjective_Prefix_Suffix` for each of `passes`, from a counter hash of (seed, pass, draw). A name
    /// used earlier in the batch draws again, so every pass's name is different while the lists allow it;
    /// past that, a number keeps them apart.
    public static func random(seed: Int, passes: Int, lists: WordLists = .builtIn) -> [String] {
        var used: Set<String> = []
        var names: [String] = []
        names.reserveCapacity(passes)
        for pass in 0..<passes {
            var name = ""
            for draw in 0..<64 {
                let key = (UInt64(truncatingIfNeeded: seed) << 40) ^ (UInt64(pass) << 8) ^ UInt64(draw)
                name = [lists.adjectives, lists.prefixes, lists.suffixes].enumerated().map { index, list in
                    list[Int(hash(key &+ UInt64(index) &* 0x1000_0000_0000) % UInt64(list.count))]
                }.joined(separator: "_")
                if !used.contains(name) { break }
            }
            if used.contains(name) { name += "_\(pass + 1)" }
            used.insert(name)
            names.append(name)
        }
        return names
    }

    /// splitmix64.
    private static func hash(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }
}
