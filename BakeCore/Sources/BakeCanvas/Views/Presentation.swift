import BakeGraph
import Foundation
import SwiftUI

/// Named coordinate space of the canvas (unscaled view points). Gestures report locations in it.
public enum CanvasSpace {
    public static let name = "bake.canvas"
}

extension NodeCategory {
    /// Submenu title in Add Node.
    public var title: String {
        switch self {
        case .inOut: "In & Out"
        case .batch: "Batch"
        case .effects: "Effects"
        case .time: "Time"
        case .spectral: "Spectral"
        case .wavetable: "Wavetable"
        case .routing: "Routing"
        case .modulation: "Modulation"
        case .custom: "Custom"
        }
    }
}

extension NodeSubgroup {
    /// Submenu title inside Effects.
    public var title: String {
        switch self {
        case .filters: "Filters"
        case .distortion: "Distortion"
        case .dynamics: "Dynamics"
        case .modulationFX: "Modulation FX"
        }
    }
}

extension SignalType {
    /// Wire and pin color: audio and control signals are told apart at a glance.
    public var color: Color {
        switch self {
        case .audio: .orange
        case .control: .teal
        }
    }
}

extension NodeKind {
    /// Nodes whose every output is a control signal (LFO, Envelope, Math, …) — modulation sources.
    public var isModulationSource: Bool {
        let outputs = NodeCatalog.outputSignals(of: self)
        return !outputs.isEmpty && outputs.allSatisfy { $0 == .control }
    }

    /// Card border and header dot: modulation sources wear the control-wire colour, the rest the accent.
    var cardColor: Color {
        isModulationSource ? SignalType.control.color : .accentColor
    }
}

public enum ParameterFormat {
    /// A value with its unit: "440 Hz", "1.23 kHz", "-3 st", "2.5×". Up to two decimals.
    public static func string(_ value: Double, unit: String, locale: Locale = .current) -> String {
        func number(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        }
        switch unit {
        case "Hz" where abs(value) >= 1_000: return "\(number(value / 1_000)) kHz"
        case "": return number(value)
        case "×", "°": return number(value) + unit
        default: return "\(number(value)) \(unit)"
        }
    }

    /// "4.0 s", "42 s", "16 min 40 s", "1 h 5 min".
    public static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        switch seconds {
        case ..<1:
            // A wavetable cycle is 43 ms: "0.0 s" would hide it.
            return "\(Int((seconds * 1_000).rounded())) ms"
        case ..<10:
            return seconds.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX"))) + " s"
        case ..<60:
            return "\(whole) s"
        case ..<3_600:
            return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(whole % 60) s"
        default:
            return "\(whole / 3_600) h \(whole % 3_600 / 60) min"
        }
    }

    /// Display title for a stored choice.
    public static func title(forChoice choice: String, of parameter: ParameterID) -> String {
        switch parameter {
        case "slope": return "\(choice) dB/oct"
        case "bitDepth": return choice == "32f" ? "32-bit float" : "\(choice)-bit"
        case "oversampling": return "\(choice)×"
        case "pattern" where choice == "cantor": return "Cantor Set"
        case "pattern" where choice == "mandelbrot": return "Mandelbrot"
        case "pattern" where choice == "julia": return "Julia"
        case "pattern" where choice == "koch": return "Koch Snowflake"
        case "phaseMode" where choice == "preserved": return "Exact Preserved Phase"
        case "phaseMode" where choice == "randomized": return "Phase Randomize"
        case "phaseMode" where choice == "mirrored": return "Phase Mirror"
        case "root": return Int(choice).map { noteNames[$0 % 12] } ?? choice
        case "firTaps": return "\(choice) taps"
        // Large Audio Processor's Musical Time length.
        case "bars":
            switch choice {
            case "0.25": return "1/4 Bar"
            case "0.5": return "1/2 Bar"
            case "1": return "1 Bar"
            default: return "\(choice) Bars"
            }
        // Only the Filters' phase names its filter design; other "linear" choices are plain Linear.
        case "phase" where choice == "minimum": return "Minimum (IIR)"
        case "phase" where choice == "linear": return "Linear (FIR)"
        // Pitch Follower.
        case "output" where choice == "linear": return "Linear Hz"
        case "unvoiced" where choice == "hold": return "Hold Last"
        case "unvoiced" where choice == "fallToMin": return "Fall to Min"
        case "division":
            if choice.hasSuffix("d") { return "\(choice.dropLast()) dotted" }
            if choice.hasSuffix("t") { return "\(choice.dropLast()) triplet" }
            return choice
        default: return choiceTitles[choice] ?? words(choice)
        }
    }

    /// A stored id as words: `trueStereo` → "True Stereo", `rms` → "Rms" (ids that need more, like
    /// "RMS", have their own title above).
    private static func words(_ id: String) -> String {
        var spaced = ""
        for (index, character) in id.enumerated() {
            if index > 0, character.isUppercase, let previous = spaced.last, previous.isLowercase { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    private static let choiceTitles = [
        "lowpass": "Low-pass", "highpass": "High-pass", "bandpass": "Band-pass", "notch": "Notch",
        "rms": "RMS", "leftRight": "Left / Right", "midSide": "Mid / Side", "trackAndHold": "Track & Hold",
        "sampleAndHold": "Sample & Hold", "abs": "Absolute Value", "hardClip": "Hard Clip",
        "logarithmic": "Logarithmic", "bark": "Bark", "mel": "Mel",
        "and": "AND", "or": "OR", "xor": "XOR", "not": "NOT",
        "newVersion": "Save a New Version", "overwrite": "Replace It", "skip": "Skip It",
        "wav": "WAV Only", "matchRate": "Project Rate Only", "size": "File Size",
        "transient": "Transient", "musical": "Musical Time", "seconds": "Seconds",
        "index": "Input Index", "shortest": "Shortest First", "longest": "Longest First",
        "poisson": "Poisson", "uniform": "Uniform", "euclidean": "Euclidean", "inOrder": "In Order",
        "mean": "Mean", "median": "Median", "geometric": "Geometric Mean", "start": "Start", "peak": "Peak",
        "oneShot": "One-shot", "pingPong": "Ping-pong", "overLength": "Over Length",
    ]
}

/// Slider position (0…1) ↔ parameter value. Exponential parameters (frequencies) move in octaves.
public struct SliderMapping: Sendable {
    let range: ClosedRange<Double>
    let isExponential: Bool
    /// Set for a `power` taper; wins over `isExponential`.
    let power: Double?

    public init(range: ClosedRange<Double>, scale: ModulationScale, taper: SliderTaper = .automatic) {
        self.range = range
        if case .power(let k) = taper, k > 0 { power = k } else { power = nil }
        // Frequencies move in octaves. Any positive range spanning 100× or more is logarithmic too,
        // so small values (Ratio 1× in 0.1–1000×) aren't crushed against the left edge.
        let isWide = range.lowerBound > 0 && range.upperBound / range.lowerBound >= 100
        isExponential = range.lowerBound > 0 && (scale == .exponential || isWide)
    }

    public func position(for value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard range.upperBound > range.lowerBound else { return 0 }
        if let power {
            return pow((clamped - range.lowerBound) / (range.upperBound - range.lowerBound), 1 / power)
        }
        if isExponential {
            return log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    public func value(at position: Double) -> Double {
        let p = min(max(position, 0), 1)
        if let power {
            return range.lowerBound + pow(p, power) * (range.upperBound - range.lowerBound)
        }
        if isExponential {
            return range.lowerBound * pow(range.upperBound / range.lowerBound, p)
        }
        return range.lowerBound + p * (range.upperBound - range.lowerBound)
    }
}
