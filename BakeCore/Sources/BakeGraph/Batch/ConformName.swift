import Foundation

/// The tempo and key a file's name gives (`drums_128bpm`, `Bass 92 BPM Am`, `pad_F#min`), for Batch Conform.
public enum ConformName {
    public struct Key: Hashable, Sendable {
        /// Pitch class of the root: 0 = C … 11 = B.
        public var root: Int
        public var minor: Bool

        public init(root: Int, minor: Bool) {
            self.root = ((root % 12) + 12) % 12
            self.minor = minor
        }
    }

    /// A number from 40 to 300 next to "bpm" (either side, with or without a space).
    public static func bpm(in name: String) -> Double? {
        let text = name.lowercased()
        let patterns = [#"(\d{2,3}(?:\.\d+)?)\s*-?\s*bpm"#, #"bpm\s*-?\s*(\d{2,3}(?:\.\d+)?)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let value = Double(text[range]), (40...300).contains(value) else { continue }
            return value
        }
        return nil
    }

    /// A key on its own between separators: a letter A–G, then ♯/#/♭/b, then m/min/minor/maj/major (or nothing,
    /// which is major). The last one in the name wins, since keys usually come last.
    public static func key(in name: String) -> Key? {
        let pattern = #"(?:^|[\s_\-.()\[\]])([A-Ga-g])(#|♯|b|♭)?\s?(minor|min|m|major|maj|M)?(?=$|[\s_\-.()\[\]])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: name, range: NSRange(name.startIndex..., in: name))
        for match in matches.reversed() {
            guard let letterRange = Range(match.range(at: 1), in: name) else { continue }
            let letter = name[letterRange]
            let accidental = Range(match.range(at: 2), in: name).map { String(name[$0]) }
            let quality = Range(match.range(at: 3), in: name).map { String(name[$0]) }
            // A lone lower-case letter ("a", "b") is too likely an ordinary word.
            if letter.first?.isLowercase == true, accidental == nil, quality == nil { continue }
            let roots: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
            guard let natural = roots[Character(letter.uppercased())] else { continue }
            let shift = accidental.map { $0 == "#" || $0 == "♯" ? 1 : -1 } ?? 0
            let minor = quality.map { ["m", "min", "minor"].contains($0) } ?? false
            return Key(root: natural + shift, minor: minor)
        }
        return nil
    }
}

/// What Batch Conform does to one file: its `ratio` (output length over input length) and `shift` (semitones),
/// from the tempo and key its name gives, else the detected ones, and the targets.
public enum ConformPlan {
    public struct Settings: Hashable, Sendable {
        public var ratio: Double
        public var shift: Int
        /// The tempo and key it went by (nil: none found, so that part was left alone).
        public var bpm: Double?
        public var key: ConformName.Key?
    }

    /// `bpm` times or divided by 2 until it's as near `target` as it gets (within a factor of √2).
    public static func fold(_ bpm: Double, to target: Double) -> Double {
        var value = bpm
        while value < target / 2.squareRoot() { value *= 2 }
        while value > target * 2.squareRoot() { value /= 2 }
        return value
    }

    /// The nearest move from `root` to `target` (pitch classes): −6 to +5 semitones.
    public static func nearestShift(from root: Int, to target: Int) -> Int {
        let up = ((target - root) % 12 + 12) % 12
        return up > 5 ? up - 12 : up
    }

    public static func settings(
        _ parameters: [ParameterID: ParameterValue], name: String?, detectedBPM: Double?, detectedKey: ConformName.Key?
    ) -> Settings {
        let mode = parameters["conform"].flatMap { if case .choice(let v) = $0 { v } else { nil } } ?? "tempoKey"
        let target = parameters["targetBPM"]?.numberValue ?? 120
        let targetKey = parameters["targetKey"].flatMap { if case .choice(let v) = $0 { NodeCatalog.conformKeys.firstIndex(of: v) } else { nil } } ?? 0
        let depth = (parameters["depth"]?.numberValue ?? 100) / 100
        let bpm = (name.flatMap(ConformName.bpm(in:)) ?? detectedBPM).map { fold($0, to: target) }
        let key = name.flatMap(ConformName.key(in:)) ?? detectedKey
        var settings = Settings(ratio: 1, shift: 0, bpm: bpm, key: key)
        if mode != "key", let bpm, bpm > 0 { settings.ratio = pow(bpm / target, depth) }
        if mode != "tempo", let key { settings.shift = nearestShift(from: key.root, to: targetKey) }
        return settings
    }
}
