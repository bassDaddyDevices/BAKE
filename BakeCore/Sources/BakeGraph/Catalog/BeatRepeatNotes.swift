/// Beat Repeat's note values: "n/d" is n÷d of a whole note (a 4/4 bar), "t" makes it a triplet (× 2/3).
/// Documents store these IDs. Tempo counts quarter notes.
public enum BeatRepeatNotes {
    /// Slice lengths, longest first. Past 1/64 the repeats turn into pitched buzz.
    public static let grids = [
        "1/4", "1/8", "1/8t", "1/16", "1/16t", "1/32", "1/32t", "1/64", "1/128", "1/256", "1/512", "1/1024", "1/2048",
    ]
    /// How often an event can start.
    public static let intervals = ["1/4", "1/2", "1/1", "2/1", "4/1"]

    /// Length in quarter notes, or nil for an unknown ID.
    public static func quarterNotes(_ id: String) -> Double? {
        var body = Substring(id)
        var factor = 1.0
        if body.hasSuffix("t") {
            factor = 2.0 / 3.0
            body = body.dropLast()
        }
        let parts = body.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator > 0 else { return nil }
        return 4 * numerator / denominator * factor
    }

    /// Frames per note value at `bpm`. Unknown IDs count as a sixteenth.
    public static func frames(_ id: String, bpm: Double, sampleRate: Double) -> Double {
        (quarterNotes(id) ?? 0.25) * 60 / bpm * sampleRate
    }
}
