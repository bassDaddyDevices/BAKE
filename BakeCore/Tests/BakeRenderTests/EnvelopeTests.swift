import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct EnvelopeTests {
    private func render(
        frames: Int = 48_000, sampleRate: Double = 48_000,
        attack: Float = 0.1, decay: Float = 0.1, sustain: Float = 0.6, release: Float = 0.1,
        curve: bake.dsp.EnvelopeCurve = .linear, loop: bake.dsp.EnvelopeLoop = .off, timeScale: Float = 1,
        triggerValues: [Float]? = nil, attackModulation: [Float]? = nil, decayModulation: [Float]? = nil,
        sustainModulation: [Float]? = nil, releaseModulation: [Float]? = nil, chunk: Int? = nil,
        mode: bake.dsp.EnvelopeTriggerMode = .classic
    ) -> [Float] {
        var state = bake.dsp.EnvelopeState()
        var output = [Float](repeating: 0, count: frames)
        var attackSignal = signal(attack, 0.001, 10, scale: .exponential)
        var decaySignal = signal(decay, 0.001, 10, scale: .exponential)
        var sustainSignal = signal(sustain, 0, 1)
        var releaseSignal = signal(release, 0.001, 10, scale: .exponential)
        let scaleSignal = signal(timeScale, 0.1, 10, scale: .exponential)
        let triggerSamples = triggerValues ?? []
        let attackValues = attackModulation ?? []
        let decayValues = decayModulation ?? []
        let sustainValues = sustainModulation ?? []
        let releaseValues = releaseModulation ?? []
        attackValues.withUnsafeBufferPointer { pointer in
            if attackModulation != nil { attackSignal.modulation = pointer.baseAddress; attackSignal.modulationFrames = pointer.count }
            decayValues.withUnsafeBufferPointer { pointer in
                if decayModulation != nil { decaySignal.modulation = pointer.baseAddress; decaySignal.modulationFrames = pointer.count }
                sustainValues.withUnsafeBufferPointer { pointer in
                    if sustainModulation != nil { sustainSignal.modulation = pointer.baseAddress; sustainSignal.modulationFrames = pointer.count }
                    releaseValues.withUnsafeBufferPointer { pointer in
                        if releaseModulation != nil { releaseSignal.modulation = pointer.baseAddress; releaseSignal.modulationFrames = pointer.count }
                        triggerSamples.withUnsafeBufferPointer { triggerPointer in
                            var trigger = bake.dsp.ControlInput()
                            trigger.samples = triggerPointer.baseAddress
                            trigger.frames = triggerPointer.count
                            output.withUnsafeMutableBufferPointer { destination in
                                var start = 0
                                while start < frames {
                                    let count = min(chunk ?? frames, frames - start)
                                    bake.dsp.renderEnvelope(
                                        &state, curve, loop, mode, attackSignal, decaySignal, sustainSignal, releaseSignal,
                                        scaleSignal, trigger, sampleRate, destination.baseAddress! + start, start, count
                                    )
                                    start += count
                                }
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    // MARK: trigger modes
    // Sample rate 10: attack 0.5 s = 5 samples, decay 0.2 s = 2, release 0.2 s = 2, sustain 0.5.

    private func shortGate(_ mode: bake.dsp.EnvelopeTriggerMode, _ gate: [Float]) -> [Float] {
        render(frames: gate.count, sampleRate: 10, attack: 0.5, decay: 0.2, sustain: 0.5, release: 0.2, triggerValues: gate, mode: mode)
    }

    private func close(_ a: [Float], _ b: [Float]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 } }

    private let twoFrameGate: [Float] = [1, 1] + [Float](repeating: 0, count: 10)

    @Test func classicIgnoresAGateThatEndsMidAttack() {
        #expect(close(shortGate(.classic, twoFrameGate), [0.2, 0.4, 0.6, 0.8, 1, 0.75, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]))
    }

    @Test func oneShotPlaysTheWholeShapeWhateverTheGate() {
        #expect(close(shortGate(.oneShot, twoFrameGate), [0.2, 0.4, 0.6, 0.8, 1, 0.75, 0.5, 0.25, 0, 0, 0, 0]))
    }

    @Test func gateReleasesTheMomentTheGateEnds() {
        #expect(close(shortGate(.gate, twoFrameGate), [0.2, 0.4, 0.2, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        let long = [Float](repeating: 1, count: 9) + [0, 0, 0]
        #expect(close(shortGate(.gate, long), [0.2, 0.4, 0.6, 0.8, 1, 0.75, 0.5, 0.5, 0.5, 0.25, 0, 0]))
    }

    @Test func retriggersStartFromTheCurrentLevel() {
        var gate = [Float](repeating: 0, count: 12)
        gate[0] = 1
        gate[7] = 1                                         // second bang mid-release (level 0.5 after frame 6)
        let output = shortGate(.oneShot, gate)
        #expect(abs(output[7] - 0.6) < 1e-6)                // 0.5 + (1 − 0.5) / 5, not 0.2
        #expect(abs(shortGate(.classic, gate)[7] - 0.2) < 1e-6)
    }

    @Test func unwiredIsTheSameInEveryMode() {
        let classic = render(frames: 2_000, attack: 0.01, decay: 0.01, release: 0.01)
        #expect(render(frames: 2_000, attack: 0.01, decay: 0.01, release: 0.01, mode: .oneShot) == classic)
        #expect(render(frames: 2_000, attack: 0.01, decay: 0.01, release: 0.01, mode: .gate) == classic)
    }

    @Test(arguments: [bake.dsp.EnvelopeTriggerMode.classic, .oneShot, .gate])
    func everyModeIsChunkInvariant(mode: bake.dsp.EnvelopeTriggerMode) {
        var gate = [Float](repeating: 0, count: 20_000)
        for start in [0, 2_331, 9_000, 15_539] { for frame in start..<(start + 900) { gate[frame] = 1 } }
        let whole = render(frames: 20_000, attack: 0.05, decay: 0.05, release: 0.05, triggerValues: gate, mode: mode)
        #expect(render(frames: 20_000, attack: 0.05, decay: 0.05, release: 0.05, triggerValues: gate, chunk: 777, mode: mode) == whole)
    }

    @Test func untriggeredAdsrMatchesLinearKnownAnswer() {
        let output = render(frames: 12, sampleRate: 10, attack: 0.4, decay: 0.4, sustain: 0.5, release: 0.2)
        #expect(output[0] == 0.25)
        #expect(output[3] == 1)
        // Attack fills frames 0–3 (0.25 … 1); decay's first sample is already a quarter of the way down.
        #expect(output[4] == 0.875)
        #expect(output[7] == 0.5)
        #expect(output[9] == 0)
    }

    @Test func risingGateTriggersAndFallingGateReleases() {
        let gate = [Float](repeating: 0, count: 2) + [Float](repeating: 1, count: 6) + [Float](repeating: 0, count: 6)
        let output = render(frames: gate.count, sampleRate: 10, attack: 0.2, decay: 0.2, sustain: 0.5, release: 0.3, triggerValues: gate)
        #expect(output[0] == 0)
        #expect(output[2] > output[1])
        #expect(output[7] >= output[6])
        #expect(output[8] < output[7])
        #expect(output[11] < output[9])
        #expect(output[13] == 0)
    }

    @Test func sustainLoopRetriggersWhileGateIsHeld() {
        let gate = [Float](repeating: 0, count: 2) + [Float](repeating: 1, count: 18)
        let output = render(frames: gate.count, sampleRate: 10, attack: 0.2, decay: 0.2, sustain: 0.4, loop: .attackDecay, triggerValues: gate)
        let late = Array(output[8...])
        #expect(late.max() ?? 0 > 0.8)
        #expect(late.min() ?? 1 < 0.6)
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let gate = (0..<12_000).map { frame in frame % 4_000 < 2_500 ? Float(1) : Float(0) }
        let whole = render(frames: gate.count, triggerValues: gate)
        #expect(render(frames: gate.count, triggerValues: gate, chunk: 777) == whole)
    }

    @Test func repeatedRendersAreDeterministic() {
        let gate = (0..<8_000).map { $0 % 3_000 < 1_500 ? Float(1) : Float(0) }
        #expect(render(frames: gate.count, triggerValues: gate) == render(frames: gate.count, triggerValues: gate))
    }

    @Test func allParameterAndSettingExtremesStayFinite() {
        for attack in [Float(0.001), 10] {
            for decay in [Float(0.001), 10] {
                for sustain in [Float(0), 1] {
                    for release in [Float(0.001), 10] {
                        for scale in [Float(0.1), 10] {
                            for curve in [bake.dsp.EnvelopeCurve.linear, .exponential] {
                                for loop in [bake.dsp.EnvelopeLoop.off, .attackDecay] {
                                    let trigger = [Float](repeating: 1, count: 1_024)
                                    #expect(render(frames: 1_024, attack: attack, decay: decay, sustain: sustain, release: release, curve: curve, loop: loop, timeScale: scale, triggerValues: trigger).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func everyModulatableParameterChangesOutput() {
        let frames = 6_000
        let gate = [Float](repeating: 1, count: 3_000) + [Float](repeating: 0, count: 3_000)
        let modulation = (0..<frames).map { Float($0 < frames / 2 ? -1 : 1) }
        #expect(render(frames: frames, attack: 0.01, triggerValues: gate) != render(frames: frames, attack: 0.01, triggerValues: gate, attackModulation: modulation))
        #expect(render(frames: frames, attack: 0.01, decay: 0.1, triggerValues: gate) != render(frames: frames, attack: 0.01, decay: 0.1, triggerValues: gate, decayModulation: modulation))
        #expect(render(frames: frames, attack: 0.01, decay: 0.01, sustain: 0.5, triggerValues: gate) != render(frames: frames, attack: 0.01, decay: 0.01, sustain: 0.5, triggerValues: gate, sustainModulation: modulation))
        #expect(render(frames: frames, attack: 0.01, decay: 0.01, release: 0.1, triggerValues: gate) != render(frames: frames, attack: 0.01, decay: 0.01, release: 0.1, triggerValues: gate, releaseModulation: modulation))
    }

    @Test func bothCurveAndLoopSettingsChangeTheEnvelope() {
        let gate = (0..<8_000).map { $0 < 4_000 ? Float(1) : Float(0) }
        #expect(render(frames: gate.count, sampleRate: 1_000, attack: 1, decay: 1, curve: .linear, triggerValues: gate) != render(frames: gate.count, sampleRate: 1_000, attack: 1, decay: 1, curve: .exponential, triggerValues: gate))
        let heldGate = [Float](repeating: 1, count: 8_000)
        #expect(render(frames: heldGate.count, sampleRate: 1_000, attack: 0.2, decay: 0.2, sustain: 0.5, loop: .off, triggerValues: heldGate) != render(frames: heldGate.count, sampleRate: 1_000, attack: 0.2, decay: 0.2, sustain: 0.5, loop: .attackDecay, triggerValues: heldGate))
    }

    @Test func lfoEnvelopeFiltersPrintChainPreservesAudioShapeAndUsesEnvelope() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = [sine(frequency: 440, frames: 8_192)]
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let lfo = graph.add(.lfo, ["shape": .choice("square"), "rate": .number(3)])
        let envelope = graph.add(.envelope, ["attack": .number(0.01), "decay": .number(0.02), "sustain": .number(0.25), "release": .number(0.05)])
        let filters = graph.add(.filters, ["cutoff": .number(700), "slope": .choice("24")])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        let filterIndex = try #require(graph.project.nodes.firstIndex { $0.id == filters })
        graph.project.nodes[filterIndex].setModulated("cutoff", true)
        graph.connect(audio, to: filters)
        graph.connect(lfo, to: envelope, "trigger")
        graph.connect(envelope, to: filters, "mod.cutoff")
        graph.connect(filters, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        let written = try #require(try await RenderEngine.render(request).outputs[print])
        let rendered = try TestAudio.read(written).samples
        #expect(rendered.count == 1)
        #expect(rendered[0].count == 8_192)
        #expect(rendered[0].allSatisfy { $0.isFinite })
        #expect(rendered[0] != samples[0])
    }

    /// Clock (240 BPM quarters, 10 % gate = 1200 frames) → Envelope (attack 0.1 s = 4800 frames) →
    /// Gain/VCA (ring mod) Amount on constant 0.5 audio → Bake.
    private func clockedEnvelope(_ mode: String) async throws -> [Float] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioFile = directory.appendingPathComponent("dc.wav")
        try TestAudio.write([[Float](repeating: 0.5, count: 12_000)], to: audioFile, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let clock = graph.add(.clock, ["bpm": .number(240), "division": .choice("1/4")])
        let envelope = graph.add(.envelope, ["triggerMode": .choice(mode), "attack": .number(0.1)])
        let gain = graph.add(.gainVCA, ["mode": .choice("ringMod")])
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(clock, to: envelope, "trigger")
        graph.connect(envelope, to: gain, "amount")
        graph.connect(audio, to: gain)
        graph.connect(gain, to: print)
        let urls = [sourceAsset: audioFile]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples[0]
    }

    @Test func aClockBangPlaysTheWholeOneShotEvenWithAShortGate() async throws {
        let oneShot = try await clockedEnvelope("oneShot")
        #expect(abs(oneShot[4_799] - 0.5) < 1e-3)          // full peak although the gate ended at 1200
        let gated = try await clockedEnvelope("gate")
        #expect(gated[4_799] < 0.1)                         // released when the gate ended
    }
}
