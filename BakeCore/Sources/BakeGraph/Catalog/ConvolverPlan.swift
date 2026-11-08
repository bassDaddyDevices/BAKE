import Foundation

/// How long a Convolver's output is and how many channels it has. The compiler uses it for the node's shape and the
/// renderer for the impulse response it builds, so the two always agree. Only static parameters feed it.
public enum ConvolverPlan {
    /// The parameters that change the impulse response's length (and so the output's).
    public static let lengthParameters: [ParameterID] = ["trim", "stretch", "preDelay", "stereo"]

    /// Frames of the impulse response kept from a source of `raw` frames: the first `trim` seconds (0 = all).
    public static func trimmedFrames(raw: Int, parameters: [ParameterID: ParameterValue], sampleRate: Double) -> Int {
        let trim = parameters["trim"]?.numberValue ?? 0
        guard trim > 0 else { return raw }
        return min(raw, max(Int((trim * sampleRate).rounded()), 1))
    }

    public static func stretch(_ parameters: [ParameterID: ParameterValue]) -> Double {
        let value = parameters["stretch"]?.numberValue ?? 1
        return value > 0 && value.isFinite ? value : 1
    }

    public static func preDelayFrames(_ parameters: [ParameterID: ParameterValue], sampleRate: Double) -> Int {
        max(Int(((parameters["preDelay"]?.numberValue ?? 0) * 0.001 * sampleRate).rounded()), 0)
    }

    /// The impulse response after trim, stretch and pre-delay, from a source of `raw` frames.
    public static func impulseFrames(raw: Int, parameters: [ParameterID: ParameterValue], sampleRate: Double) -> Int {
        let kept = trimmedFrames(raw: raw, parameters: parameters, sampleRate: sampleRate)
        let stretched = max(Int((Double(kept) * stretch(parameters)).rounded()), 1)
        return stretched + preDelayFrames(parameters, sampleRate: sampleRate)
    }

    /// True stereo reads a four-channel impulse response (LL, LR, RL, RR: input to output); anything else is matrix.
    public static func usesTrueStereo(_ parameters: [ParameterID: ParameterValue], impulseChannels: Int, impulseIsWired: Bool) -> Bool {
        parameters["stereo"] == .choice("trueStereo") && impulseIsWired && impulseChannels >= 4
    }

    /// The output: input + impulse − 1 frames. `impulse` is the impulse source's shape, or nil when `ir` is unwired
    /// and the input convolves with itself.
    public static func shape(input: SignalShape, impulse: SignalShape?, parameters: [ParameterID: ParameterValue], sampleRate: Double) -> SignalShape {
        let source = impulse ?? input
        let frames = input.frames + impulseFrames(raw: source.frames, parameters: parameters, sampleRate: sampleRate) - 1
        if usesTrueStereo(parameters, impulseChannels: source.channels, impulseIsWired: impulse != nil) {
            return SignalShape(frames: frames, channels: 2)
        }
        return SignalShape(frames: frames, channels: max(input.channels, source.channels))
    }
}
