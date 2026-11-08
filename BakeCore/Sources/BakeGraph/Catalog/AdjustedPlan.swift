import Foundation

/// How long a Utility's output is once Trim and Pad are applied. The compiler uses it for the node's shape and the
/// renderer for where the audio sits in the output, so the two always agree. Only static parameters feed it.
///
/// Trim cuts from the ends of the input first; Pad then adds silence outside what is left.
public enum AdjustedPlan {
    public struct Frames: Equatable, Sendable {
        public var trimStart = 0
        public var trimEnd = 0
        public var padStart = 0
        public var padEnd = 0

        public init(trimStart: Int = 0, trimEnd: Int = 0, padStart: Int = 0, padEnd: Int = 0) {
            self.trimStart = trimStart
            self.trimEnd = trimEnd
            self.padStart = padStart
            self.padEnd = padEnd
        }

        /// The input's frames that are kept, 0 when the trims meet or pass each other.
        public func kept(of inputFrames: Int) -> Int { max(inputFrames - trimStart - trimEnd, 0) }

        /// The output's length: what is kept, with the pads around it.
        public func output(of inputFrames: Int) -> Int { kept(of: inputFrames) + padStart + padEnd }

        public var isAtRest: Bool { trimStart == 0 && trimEnd == 0 && padStart == 0 && padEnd == 0 }
    }

    public static let parameters: [ParameterID] = ["trimStart", "trimEnd", "padStart", "padEnd"]

    public static func frames(_ values: [ParameterID: ParameterValue], sampleRate: Double) -> Frames {
        func count(_ id: ParameterID) -> Int {
            let seconds = values[id]?.numberValue ?? 0
            guard seconds > 0, seconds.isFinite else { return 0 }
            return Int((seconds * sampleRate).rounded())
        }
        return Frames(trimStart: count("trimStart"), trimEnd: count("trimEnd"), padStart: count("padStart"), padEnd: count("padEnd"))
    }
}
