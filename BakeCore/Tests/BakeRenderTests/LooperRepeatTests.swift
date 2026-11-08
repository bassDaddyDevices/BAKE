import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// The Looper's Repeat mode (issue 001): each bang loops the Length that follows it until the next
/// bang, and the output is as long as the input. At 48 kHz, 100 ms is 4800 frames.
struct LooperRepeatTests {
    private struct Settings {
        var every = 100.0, length = 50.0, passes = 64.0, shrink = 1.0
        var direction = 0.0, decay = 0.0, pitch = 0.0, crossfade = 0.0
        var everyModulation: [Float]? = nil
    }

    private func render(_ source: [Float], _ settings: Settings = Settings(), trigger: [Float]? = nil, chunk: Int? = nil) -> [Float] {
        var timing = bake.dsp.LooperRepeat()
        timing.every = signal(Float(settings.every), 10, 30_000)
        timing.length = signal(Float(settings.length), 1, 30_000)
        timing.passes = signal(Float(settings.passes), 1, 64)
        timing.shrink = signal(Float(settings.shrink), 0.5, 2)
        var controls = bake.dsp.LooperControls()
        controls.scrub = signal(0, -2_000, 2_000)
        controls.direction = signal(Float(settings.direction), 0, 2)
        controls.pitch = signal(Float(settings.pitch), -24, 24)
        controls.pitchDrift = signal(0, -12, 12)
        controls.decay = signal(Float(settings.decay), 0, 1)
        controls.crossfade = signal(Float(settings.crossfade), 0, 200)
        controls.sampleRate = 48_000

        let everyValues = settings.everyModulation ?? []
        let triggerValues = trigger ?? []
        var state = bake.dsp.LooperState()
        var output = [Float](repeating: 0, count: source.count)
        everyValues.withUnsafeBufferPointer { everyPointer in
            triggerValues.withUnsafeBufferPointer { triggerPointer in
                source.withUnsafeBufferPointer { sourcePointer in
                    output.withUnsafeMutableBufferPointer { destination in
                        if settings.everyModulation != nil {
                            timing.every.modulation = everyPointer.baseAddress
                            timing.every.modulationFrames = everyPointer.count
                        }
                        var triggerInput = bake.dsp.ControlInput()
                        if trigger != nil { triggerInput.samples = triggerPointer.baseAddress; triggerInput.frames = triggerPointer.count }
                        var start = 0
                        while start < destination.count {
                            let count = min(chunk ?? destination.count, destination.count - start)
                            bake.dsp.renderLooperRepeat(
                                &state, timing, controls, triggerInput, sourcePointer.baseAddress, sourcePointer.count,
                                destination.baseAddress! + start, start, count
                            )
                            start += count
                        }
                    }
                }
            }
        }
        return output
    }

    private func ramp(_ frames: Int) -> [Float] { (0..<frames).map { Float($0) / Float(frames) } }

    @Test func everyBangLoopsTheLengthThatFollowsItUntilTheNext() {
        let source = ramp(48_000)
        let output = render(source)
        #expect(output.count == source.count)
        for k in [0, 1_000, 2_399] {
            #expect(output[k] == source[k])                  // the first loop, pass 1
            #expect(output[2_400 + k] == source[k])          // pass 2: the same 50 ms again
            #expect(output[4_800 + k] == source[4_800 + k])  // the next bang captures what follows it
            #expect(output[7_200 + k] == source[4_800 + k])
            #expect(output[43_200 + k] == source[43_200 + k])  // and so on, to the end
            #expect(output[45_600 + k] == source[43_200 + k])
        }
    }

    @Test func afterItsPassesTheInputPlaysLiveUntilTheNextBang() {
        let source = ramp(48_000)
        let output = render(source, Settings(length: 25, passes: 2))
        for k in [0, 600, 1_199] {
            #expect(output[1_200 + k] == source[k])  // pass 2
        }
        #expect(Array(output[2_400..<4_800]) == Array(source[2_400..<4_800]))  // live
        #expect(output[4_800] == source[4_800])
        #expect(output[6_000] == source[4_800])  // the next loop
    }

    @Test func aWiredTriggerStartsEachLoopAndTheInputPlaysLiveBeforeTheFirst() {
        let source = ramp(48_000)
        var trigger = [Float](repeating: 0, count: 48_000)
        for frame in 10_000..<10_100 { trigger[frame] = 1 }
        for frame in 30_000..<30_100 { trigger[frame] = 1 }
        let output = render(source, trigger: trigger)
        #expect(Array(output[0..<10_000]) == Array(source[0..<10_000]))
        #expect(output[12_400] == source[10_000])  // 50 ms passes of what followed the bang…
        #expect(output[29_999] == output[29_999 - 2_400])  // …until the next one
        #expect(output[30_000] == source[30_000])
        #expect(output[32_400] == source[30_000])
    }

    @Test func shrinkDecayAndReverseShapeEachPass() {
        let source = ramp(48_000)
        let shrunk = render(source, Settings(shrink: 0.5))
        #expect(shrunk[2_400] == source[0])  // pass 2 starts after 2400 frames…
        #expect(shrunk[3_600] == source[0])  // …and is 1200 long
        let decayed = render(source, Settings(decay: 0.5))
        #expect(abs(decayed[2_400 + 1_000] - source[1_000] * 0.5) < 1e-6)
        let reversed = render(source, Settings(direction: 1))
        #expect(reversed[0] == source[2_399])
        #expect(reversed[2_399] == source[0])
    }

    @Test func chunksOf777MatchOneWholeRender() {
        let source = (0..<60_000).map { Float(sin(Double($0) / 37)) * 0.4 }
        var settings = Settings(length: 70, passes: 5, shrink: 0.8, direction: 2, decay: 0.2, pitch: 3, crossfade: 8)
        settings.everyModulation = (0..<60_000).map { Float(sin(Double($0) / 9_000)) * 0.5 }
        var trigger = [Float](repeating: 0, count: 60_000)
        for frame in stride(from: 3_000, to: 60_000, by: 11_000) { trigger[frame] = 1 }
        #expect(render(source, settings, chunk: 777) == render(source, settings))
        #expect(render(source, settings, trigger: trigger, chunk: 777) == render(source, settings, trigger: trigger))
    }

    @Test func extremesStayFinite() {
        let source = (0..<20_000).map { Float(sin(Double($0) / 5)) }
        for settings in [Settings(every: 10, length: 1, passes: 64, shrink: 0.5), Settings(every: 30_000, length: 30_000, shrink: 2, pitch: 24)] {
            #expect(render(source, settings).allSatisfy { $0.isFinite })
        }
    }

    @Test func newLoopersRepeatAndRenderAtTheInputsLength() async throws {
        #expect(NodeCatalog.defaultParameters(for: .looper)["mode"] == .choice("repeat"))
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 30_000, channels: 2), to: file, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let looper = graph.add(.looper, NodeCatalog.defaultParameters(for: .looper))
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: looper)
        graph.connect(looper, to: print)
        let urls = [sourceAsset: file]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        let rendered = try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print]))
        #expect(rendered.samples.count == 2 && rendered.samples[0].count == 30_000)
    }

    @Test func loopersSavedBeforeRepeatKeepLoopingOnce() throws {
        let looper = Node(kind: .looper, parameters: ["length": .number(250)])
        var project = ProjectFile(schemaVersion: 5, nodes: [looper])
        ProjectMigration.migrate(&project)
        #expect(project.nodes[0].parameters["mode"] == .choice("once"))
        var current = ProjectFile(nodes: [looper])
        ProjectMigration.migrate(&current)
        #expect(current.nodes[0].parameters["mode"] == nil)
    }
}
