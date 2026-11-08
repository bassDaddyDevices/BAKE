/// The Clock's note values: 1/1 … 1/64, each also dotted ("1/4d", × 1.5) or triplet ("1/4t", × 2/3).
/// Documents store these IDs. BPM counts quarter notes.
public enum ClockDivision {
    private static let denominators = [1, 2, 4, 8, 16, 32, 64]

    /// Plain, dotted, triplet for each note value, longest first.
    public static let ids: [String] = denominators.flatMap { ["1/\($0)", "1/\($0)d", "1/\($0)t"] }

    /// Length in quarter notes, or nil for an unknown ID.
    public static func quarterNotes(_ id: String) -> Double? {
        var body = Substring(id)
        var factor = 1.0
        if body.hasSuffix("d") {
            factor = 1.5
            body = body.dropLast()
        } else if body.hasSuffix("t") {
            factor = 2.0 / 3.0
            body = body.dropLast()
        }
        guard body.hasPrefix("1/"), let denominator = Int(body.dropFirst(2)), denominators.contains(denominator) else { return nil }
        return 4.0 / Double(denominator) * factor
    }

    /// Frames per division at `bpm` quarter notes per minute. Unknown IDs count as a quarter note.
    public static func frames(_ id: String, bpm: Double, sampleRate: Double) -> Double {
        (quarterNotes(id) ?? 1) * 60 / bpm * sampleRate
    }
}
