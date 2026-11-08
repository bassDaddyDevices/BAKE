import Foundation

/// Where a Looper's passes fall. The compiler uses it for the node's length and the renderer for
/// the pass boundaries, so the two always agree. Only the length parameters feed it; they are
/// fixed when the graph compiles and can't be modulated.
public enum LooperPlan {
    /// The parameters that change the output length (in Once mode).
    public static let lengthParameters: [ParameterID] = ["mode", "start", "length", "passes", "shrink", "keep"]
    /// The shortest pass, so a shrinking loop holds as a buzz instead of vanishing.
    public static let minimumPass = 16

    public struct Layout: Equatable, Sendable {
        /// The region's first source frame and its length (pass 0).
        public let regionStart: Int
        public let regionLength: Int
        public let passLengths: [Int]
        /// Output frames of input played before the passes, and after them.
        public let intro: Int
        public let tail: Int

        public var frames: Int { intro + passLengths.reduce(0, +) + tail }
    }

    /// The Looper's output length: the input's in Repeat mode, the passes' layout in Once.
    public static func frames(inputFrames: Int, parameters: [ParameterID: ParameterValue], sampleRate: Double) -> Int {
        if parameters["mode"] == .choice("repeat") { return inputFrames }
        return layout(inputFrames: inputFrames, parameters: parameters, sampleRate: sampleRate).frames
    }

    public static func layout(inputFrames: Int, parameters: [ParameterID: ParameterValue], sampleRate: Double) -> Layout {
        let start = min(max(parameters["start"]?.numberValue ?? 0, 0), 1)
        let regionStart = Int((Double(inputFrames) * start).rounded())
        let regionLength = max(Int(((parameters["length"]?.numberValue ?? 500) / 1_000 * sampleRate).rounded()), minimumPass)
        let passes = min(max(Int((parameters["passes"]?.numberValue ?? 4).rounded()), 1), 64)
        let shrink = min(max(parameters["shrink"]?.numberValue ?? 1, 0.5), 2)
        let passLengths = (0..<passes).map { max(Int((Double(regionLength) * pow(shrink, Double($0))).rounded()), minimumPass) }
        var keep = "whole"
        if case .choice(let value)? = parameters["keep"] { keep = value }
        guard keep == "whole" else {
            return Layout(regionStart: regionStart, regionLength: regionLength, passLengths: passLengths, intro: 0, tail: 0)
        }
        return Layout(
            regionStart: regionStart, regionLength: regionLength, passLengths: passLengths,
            intro: min(regionStart, inputFrames), tail: max(inputFrames - (regionStart + regionLength), 0)
        )
    }
}
