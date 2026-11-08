import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// For Each Splitter and Spectral Sorter through the session: each file written by the branch it went down.
@MainActor
struct RouterBatchTests {
    private let access = PlainFileAccess()
    private let rate = 48_000.0

    private func reference(_ url: URL, writable: Bool) throws -> FileReference {
        FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: try access.bookmark(for: url, writable: writable))
    }

    /// A mono file of `signal`.
    private func write(_ signal: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(signal.count)))
        buffer.frameLength = AVAudioFrameCount(signal.count)
        let data = try #require(buffer.floatChannelData)
        signal.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: signal.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    private func tone(_ parts: [(hertz: Double, level: Double)], frames: Int = 9_600) -> [Float] {
        (0..<frames).map { i in Float(parts.reduce(0) { $0 + $1.level * sin(2 * .pi * $1.hertz * Double(i) / rate) }) }
    }

    /// Batch Audio over `files` → `before` → `router` (with `parameters`) → one Batch Bake (32f, `naming`) per
    /// output, each into its own folder named after the pin.
    private func bake(
        _ router: NodeKind, _ parameters: [ParameterID: ParameterValue] = [:], files: [(String, [Float])],
        before: [(NodeKind, [ParameterID: ParameterValue])] = [], naming: [ParameterID: ParameterValue] = [:]
    ) async throws -> (outputs: [String: [String]], folder: URL) {
        let folder = try makeTemporaryFolder()
        let input = folder.appending(path: "in", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for (name, signal) in files { try write(signal, to: input.appending(path: "\(name).wav")) }
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        project.setSourceFolder(try reference(input, writable: false), for: source)
        var last = source
        for (kind, settings) in before {
            let node = project.addNode(kind, at: CanvasPoint())
            for (id, value) in settings { project.setParameter(id, of: node, to: value) }
            try project.connect(from: PinRef(node: last, pin: "out"), to: PinRef(node: node, pin: "in"))
            last = node
        }
        let split = project.addNode(router, at: CanvasPoint())
        for (id, value) in parameters { project.setParameter(id, of: split, to: value) }
        try project.connect(from: PinRef(node: last, pin: "out"), to: PinRef(node: split, pin: "in"))
        let pins = NodeCatalog.pins(of: try #require(project.node(split))).filter { $0.direction == .output }.map(\.id)
        for pin in pins {
            let out = folder.appending(path: pin, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let bake = project.addNode(.batchBake, at: CanvasPoint())
            project.setParameter("bitDepth", of: bake, to: .choice("32f"))
            for (id, value) in naming { project.setParameter(id, of: bake, to: value) }
            project.setOutputFolder(try reference(out, writable: true), for: bake)
            try project.connect(from: PinRef(node: split, pin: pin), to: PinRef(node: bake, pin: "in"))
        }
        let session = BakeSession(access: access)
        session.bake(project, embedWorkflow: false)
        await session.waitUntilFinished()
        guard case .finished = session.state else {
            Issue.record("the batch failed: \(session.state)")
            return ([:], folder)
        }
        var outputs: [String: [String]] = [:]
        for pin in pins {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: pin).path(percentEncoded: false))
            outputs[pin] = names.sorted()
        }
        return (outputs, folder)
    }

    @Test func roundRobinWritesEachFileOnceWithItsBranchsOwnNumbers() async throws {
        let files = (1...5).map { ("hit\($0)", tone([(200, 0.3)])) }
        let (outputs, folder) = try await bake(
            .forEachSplitter, ["mode": .choice("roundRobin")], files: files,
            naming: ["naming": .choice("numbered"), "name": .text("hit")]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(outputs["out1"] == ["hit_001.wav", "hit_002.wav", "hit_003.wav"])
        #expect(outputs["out2"] == ["hit_001.wav", "hit_002.wav"])
    }

    @Test func aMerryGoRoundDealsSevenFilesPingPongAcrossThree() async throws {
        let files = (1...7).map { ("hit\($0)", tone([(200, 0.3)])) }
        let (outputs, folder) = try await bake(.merryGoRound, ["order": .choice("pingPong")], files: files)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Passes 1 2 3 2 1 2 3 → out 1 gets hit1 and hit5, out 2 hit2, hit4 and hit6, out 3 hit3 and hit7.
        #expect(outputs["out1"] == ["hit1.wav", "hit5.wav"])
        #expect(outputs["out2"] == ["hit2.wav", "hit4.wav", "hit6.wav"])
        #expect(outputs["out3"] == ["hit3.wav", "hit7.wav"])
    }

    private var drums: [(String, [Float])] {
        [("kick1", tone([(60, 0.5)])), ("kick2", tone([(80, 0.5)])), ("kick3", tone([(100, 0.5)])),
         ("snare1", tone([(800, 0.4)])), ("snare2", tone([(1_500, 0.4)])),
         ("hat1", tone([(6_000, 0.2)])), ("hat2", tone([(8_000, 0.2)])), ("hat3", tone([(9_000, 0.2)])), ("hat4", tone([(12_000, 0.2)]))]
    }

    @Test func theSorterSendsEachClipWhereItsCentroidSaysUnchanged() async throws {
        let (outputs, folder) = try await bake(.spectralSorter, files: drums)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(outputs["low"] == ["kick1.wav", "kick2.wav", "kick3.wav"])
        #expect(outputs["mid"] == ["snare1.wav", "snare2.wav"])
        #expect(outputs["high"] == ["hat1.wav", "hat2.wav", "hat3.wav", "hat4.wav"])
        // The written file is the clip itself: the sorter only chooses where it goes.
        let written = try samples(folder.appending(path: "mid/snare2.wav"))[0]
        let original = tone([(1_500, 0.4)])
        #expect(written.count == original.count)
        #expect(zip(written, original).allSatisfy { abs($0 - $1) < 1e-6 })
        // Nothing of the measuring is left behind.
        #expect(outputs.values.joined().allSatisfy { !$0.hasPrefix("capture") })
    }

    @Test func theSorterHearsWhatReachesIt() async throws {
        let bright = [("mix", tone([(100, 0.2), (8_000, 0.4)]))]
        let (plain, folder) = try await bake(.spectralSorter, files: bright)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(plain["high"] == ["mix.wav"] && plain["low"] == [])
        let (filtered, other) = try await bake(
            .spectralSorter, files: bright, before: [(.filters, ["type": .choice("lowpass"), "cutoff": .number(300)])]
        )
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(filtered["low"] == ["mix.wav"] && filtered["high"] == [])
    }

    @Test func anUnmeasuredClipIsDroppedOrSentWhereTold() async throws {
        let files = [("quiet", [Float](repeating: 0, count: 4_800)), ("hat", tone([(9_000, 0.2)]))]
        let (dropped, folder) = try await bake(.spectralSorter, files: files)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(dropped["high"] == ["hat.wav"] && dropped["low"] == [] && dropped["mid"] == [])
        let (kept, other) = try await bake(.spectralSorter, ["unmeasured": .choice("mid")], files: files)
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(kept["mid"] == ["quiet.wav"])
    }
}
