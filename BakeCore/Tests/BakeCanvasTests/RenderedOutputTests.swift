import Testing
@testable import BakeCanvas
@testable import BakeGraph

struct RenderedOutputTests {
    private func summary(isControl: Bool = false, channels: Int = 2, peak: Float = 0.5, seconds: Double = 2) -> NodeSummary {
        NodeSummary(
            sampleRate: 48_000, frames: Int(seconds * 48_000), channels: channels, isControl: isControl,
            minimums: [-peak, -peak / 2], maximums: [peak, peak / 2], rms: [peak / 2, peak / 4],
            spectrogram: isControl ? nil : Spectrogram(columns: 2, rows: 3, values: [0, 64, 128, 192, 255, 10])
        )
    }

    @Test func theCaptionSaysLengthChannelsAndPeak() {
        #expect(RenderedOutputCaption.text(for: summary()) == "2.0 s · stereo · peak −6.0 dB")
        #expect(RenderedOutputCaption.text(for: summary(channels: 1, peak: 1, seconds: 12)) == "12 s · mono · peak +0.0 dB")
        #expect(RenderedOutputCaption.text(for: summary(channels: 6, peak: 0.25)).contains("6 ch"))
    }

    @MainActor @Test func aSpectrogramsPictureIsMadeOnceAndReused() throws {
        let spectrogram = Spectrogram(columns: 2, rows: 3, values: [0, 64, 128, 192, 255, 10])
        let first = try #require(SpectrogramImages.image(for: spectrogram))
        let again = try #require(SpectrogramImages.image(for: Spectrogram(columns: 2, rows: 3, values: [0, 64, 128, 192, 255, 10])))
        #expect(first === again)
        let other = try #require(SpectrogramImages.image(for: Spectrogram(columns: 2, rows: 3, values: [9, 64, 128, 192, 255, 10])))
        #expect(other !== first)
    }

    @Test func aControlCaptionGivesItsRange() {
        #expect(RenderedOutputCaption.text(for: summary(isControl: true, channels: 1, peak: 0.75)) == "2.0 s · control · -0.75…0.75")
    }

    /// Owner report: a long Clock bake drew as a flat line. Every slice held a bang (0 and 1), and the
    /// card drew the midpoint, 0.5, everywhere. A control now draws each slice's whole range.
    @Test func aBusyControlDrawsItsWholeRangeNotAFlatMidline() {
        let slices = 160
        let gate = NodeSummary(
            sampleRate: 48_000, frames: 48_000 * 120, channels: 1, isControl: true,
            minimums: [Float](repeating: 0, count: slices), maximums: [Float](repeating: 1, count: slices),
            rms: [Float](repeating: 0.32, count: slices), spectrogram: nil
        )
        let bands = ControlBand.slices(of: gate)
        #expect(bands.count == slices)
        #expect(bands.allSatisfy { $0.low == 0 && $0.high == 1 })
    }

    @Test func aSlowControlKeepsItsShape() {
        // An LFO slower than a slice: each slice spans a narrow part of the swing.
        let lows: [Float] = [-1, -0.5, 0, 0.5]
        let highs: [Float] = [-0.5, 0, 0.5, 1]
        let lfo = NodeSummary(
            sampleRate: 48_000, frames: 4_000, channels: 1, isControl: true,
            minimums: lows, maximums: highs, rms: [0.7, 0.3, 0.3, 0.7], spectrogram: nil
        )
        let bands = ControlBand.slices(of: lfo)
        #expect(bands.map(\.low) == lows && bands.map(\.high) == highs)
    }

    private func control(_ detail: [Float]) -> NodeSummary {
        NodeSummary(sampleRate: 48_000, frames: 48_000, channels: 1, isControl: true,
                    minimums: [0], maximums: [1], rms: [0.5], spectrogram: nil, detail: detail)
    }

    /// Math draws what arrives on A and B: the summaries of whatever is wired into them.
    @Test func aCardFindsTheSummariesOfWhatFeedsIt() throws {
        var project = ProjectFile()
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        let clock = project.addNode(.clock, at: CanvasPoint())
        let math = project.addNode(.math, at: CanvasPoint())
        try project.connect(from: PinRef(node: lfo, pin: "out"), to: PinRef(node: math, pin: "a"))
        try project.connect(from: PinRef(node: clock, pin: "out"), to: PinRef(node: math, pin: "b"))
        let lfoSummary = control([0.5]), clockSummary = control([1])
        let node = try #require(project.node(math))
        let inputs = CardInputs.summaries(feeding: node, in: project, from: [lfo: lfoSummary, clock: clockSummary])
        #expect(inputs == ["a": lfoSummary, "b": clockSummary])
        #expect(CardInputs.summaries(feeding: node, in: project, from: [:]).isEmpty)
    }

    /// A wire from a node's second output (the Pitch Follower's Confidence) finds that output's
    /// summary, not the node's first output's.
    @Test func aWireFromASecondOutputFindsThatOutput() throws {
        var project = ProjectFile()
        let follower = project.addNode(.pitchFollower, at: CanvasPoint())
        let math = project.addNode(.math, at: CanvasPoint())
        try project.connect(from: PinRef(node: follower, pin: "confidence"), to: PinRef(node: math, pin: "a"))
        try project.connect(from: PinRef(node: follower, pin: "out"), to: PinRef(node: math, pin: "b"))
        let pitch = control([0.4]), confidence = control([0.9])
        let node = try #require(project.node(math))
        let outputs = [PinRef(node: follower, pin: "out"): pitch, PinRef(node: follower, pin: "confidence"): confidence]
        #expect(CardInputs.summaries(feeding: node, in: project, from: [follower: pitch], outputs: outputs) == ["a": confidence, "b": pitch])
        // Without per-pin summaries only the first output is known.
        #expect(CardInputs.summaries(feeding: node, in: project, from: [follower: pitch]) == ["b": pitch])
    }

    @Test func triggerTicksSitOnEachRisingEdge() {
        #expect(ControlTrace.rises([1, 1, 0, 0, 0.7, 0.2, 0.9]) == [0, 4, 6])
        #expect(ControlTrace.rises([0, 0.5, 0.4]).isEmpty)          // 0.5 is not above the bang threshold
    }

    @Test func silenceIsMinusInfinity() {
        #expect(RenderedOutputCaption.decibels(0) == "−∞ dB")
    }

    @Test func theSpectrogramImageHasOnePixelPerCell() throws {
        let image = try #require(summary().spectrogram?.image())
        #expect(image.width == 2 && image.height == 3)
    }

    @Test func aMalformedSpectrogramMakesNoImage() {
        let empty = Spectrogram(columns: 0, rows: 0, values: [])
        #expect(empty.image() == nil)
    }

    @Test func theColourRampGetsBrighterAndStaysInRange() {
        var previous = -1
        for step in 0...20 {
            let color = Spectrogram.color(at: Double(step) / 20)
            let brightness = Int(color.red) + Int(color.green) + Int(color.blue)
            #expect(brightness >= previous)
            previous = brightness
        }
        let quiet = Spectrogram.color(at: 0)
        let loud = Spectrogram.color(at: 1)
        #expect(Int(quiet.red) + Int(quiet.green) + Int(quiet.blue) < 20)
        #expect(loud.red > 240 && loud.green > 240)
        #expect(Spectrogram.color(at: -3) == Spectrogram.color(at: 0) && Spectrogram.color(at: 9) == Spectrogram.color(at: 1))
    }
}
